# syntax=docker/dockerfile:1
# Plex Media Server (LinuxServer base) + up-to-date AMD VAAPI driver for newer Radeon GPUs.
#
# Why this exists:
#   Plex bundles an old Mesa "radeonsi" VAAPI driver that only recognizes gfx1100-gfx1103,
#   so AMD hardware transcoding fails out-of-the-box on newer APUs/GPUs - e.g. Strix Point
#   "Radeon 890M" (gfx1150), Strix Halo "Radeon 8050S/8060S" (gfx1151), and beyond.
#   This image injects a current, self-contained musl Mesa radeonsi driver (from Alpine)
#   so Plex can do AMD H.264 HARDWARE transcoding on these GPUs.
#
# What it does NOT do:
#   HEVC / H.265 hardware ENCODING is NOT unlocked. Plex deliberately gates HEVC hardware
#   encode to Intel QuickSync / NVIDIA NVENC / Apple VideoToolbox and excludes AMD VAAPI
#   (Plex docs state verbatim: "(AMD is not supported)"). No driver/profile/setting on the
#   server side changes that - it is a Plex software policy, not a hardware limitation.
#   This image only fixes AMD H.264 hardware transcoding. See README.md.

# ---- stage 1: build a self-contained musl Mesa VAAPI driver bundle ----
FROM alpine:3.22 AS driver
RUN apk add --no-cache mesa-va-gallium libva
RUN set -eux; \
    L=/vaapi-amdgpu/lib; mkdir -p "$L/dri" /vaapi-amdgpu/share/libdrm; \
    drv="$(readlink -f /usr/lib/dri/radeonsi_drv_video.so)"; \
    cp "$drv" "$L/dri/radeonsi_drv_video.so"; \
    # copy the full dependency closure of the driver + libva (musl + libgallium + LLVM + libdrm + ...)
    for so in "$drv" /usr/lib/libva.so.2 /usr/lib/libva-drm.so.2; do \
        ldd "$so" | awk '{print $3}' | grep -E '^/' | while read -r p; do cp -nL "$p" "$L/"; done; \
    done; \
    cp -nL /usr/lib/libva.so.2 /usr/lib/libva-drm.so.2 "$L/"; \
    cp -nL /lib/ld-musl-x86_64.so.1 "$L/"; \
    ln -sf ld-musl-x86_64.so.1 "$L/libc.musl-x86_64.so.1"; \
    cp /usr/share/libdrm/amdgpu.ids /vaapi-amdgpu/share/libdrm/

# ---- stage 2: layer the driver onto the latest LinuxServer Plex ----
FROM lscr.io/linuxserver/plex:latest

# Optional: swap the image-bundled public-channel PMS for the Plex Pass beta channel.
# Requires a Plex Pass account token, supplied ONLY as a BuildKit secret mount (never a
# build-arg/ENV) so it never lands in an image layer or `docker history` — this image is
# public. `set -eu` (no `-x`) is deliberate here: tracing would echo the token into the
# (also public) GitHub Actions build log.
ARG PLEX_CHANNEL=public
RUN --mount=type=secret,id=plex_token set -eu; \
    if [ "$PLEX_CHANNEL" = "plexpass" ]; then \
        TOKEN="$(cat /run/secrets/plex_token 2>/dev/null || true)"; \
        [ -n "$TOKEN" ] || { echo "PLEX_CHANNEL=plexpass requires the plex_token secret" >&2; exit 1; }; \
        # plex.tv/api/downloads silently IGNORES a bad/expired token and falls back to the
        # public channel instead of erroring, which would make this build silently mislabel
        # a public build as plexpass. v2/user actually enforces auth, so check there first.
        AUTH_STATUS="$(curl -s -o /dev/null -w '%{http_code}' 'https://plex.tv/api/v2/user' -H "X-Plex-Token: $TOKEN" -H 'X-Plex-Client-Identifier: plex-amd-vaapi-ci')"; \
        [ "$AUTH_STATUS" = "200" ] || { echo "plex_token failed authentication (HTTP $AUTH_STATUS) - token invalid/expired" >&2; exit 1; }; \
        apt-get update && apt-get install -y --no-install-recommends jq; \
        PLEX_RELEASE="$(curl -fsS 'https://plex.tv/api/downloads/5.json?channel=plexpass' -H "X-Plex-Token: $TOKEN" | jq -r '.computer.Linux.version')"; \
        [ -n "$PLEX_RELEASE" ] && [ "$PLEX_RELEASE" != "null" ] || { echo "could not resolve the plexpass release (bad/expired token?)" >&2; exit 1; }; \
        echo "installing plexpass release $PLEX_RELEASE"; \
        curl -fsSL -o /tmp/plexmediaserver.deb "https://downloads.plex.tv/plex-media-server-new/${PLEX_RELEASE}/debian/plexmediaserver_${PLEX_RELEASE}_amd64.deb"; \
        dpkg -i /tmp/plexmediaserver.deb; \
        rm -f /tmp/plexmediaserver.deb; \
        # /build_version is cat'd verbatim by init-adduser at boot (LSIO branding banner);
        # it's just a static file from the base image build, so rewrite it or the log keeps
        # claiming the pre-swap public version even though a newer plexpass one is installed.
        printf 'Linuxserver.io version: %s (plexpass channel via plex-amd-vaapi)\nBuild-date: %s\n' \
            "$PLEX_RELEASE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /build_version; \
        apt-get purge -y jq && apt-get autoremove -y && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

COPY --from=driver /vaapi-amdgpu /vaapi-amdgpu
RUN set -eux; \
    mkdir -p /usr/share/libdrm; \
    cp /vaapi-amdgpu/share/libdrm/amdgpu.ids /usr/share/libdrm/amdgpu.ids; \
    # 1) wrap Plex's transcoder so each forked transcode uses our driver
    cd /usr/lib/plexmediaserver; \
    if [ ! -e "Plex Transcoder.real" ]; then mv "Plex Transcoder" "Plex Transcoder.real"; fi; \
    printf '#!/bin/sh\nexport LD_LIBRARY_PATH=/vaapi-amdgpu/lib\nexport LIBVA_DRIVERS_PATH=/vaapi-amdgpu/lib/dri\nexport LIBVA_DRIVER_NAME=radeonsi\nexec "/usr/lib/plexmediaserver/Plex Transcoder.real" "$@"\n' > "Plex Transcoder"; \
    chmod +x "Plex Transcoder"; \
    # 2) inject the driver env into the Plex s6 service so PMS's own capability probe uses it too
    #    (done in-place against the CURRENT linuxserver run script so it never goes stale)
    RUN_FILE=/etc/s6-overlay/s6-rc.d/svc-plex/run; \
    if [ -f "$RUN_FILE" ] && ! grep -q vaapi-amdgpu "$RUN_FILE"; then \
        { head -n1 "$RUN_FILE"; \
          printf 'export LD_LIBRARY_PATH=/vaapi-amdgpu/lib            # vaapi-amdgpu\n'; \
          printf 'export LIBVA_DRIVERS_PATH=/vaapi-amdgpu/lib/dri\n'; \
          printf 'export LIBVA_DRIVER_NAME=radeonsi\n'; \
          tail -n +2 "$RUN_FILE"; } > "$RUN_FILE.tmp"; \
        mv "$RUN_FILE.tmp" "$RUN_FILE"; chmod +x "$RUN_FILE"; \
    fi
