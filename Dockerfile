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
