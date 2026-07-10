# plex-amd-vaapi

[LinuxServer Plex](https://docs.linuxserver.io/images/docker-plex/) + an up-to-date AMD
**VAAPI** driver, so **AMD H.264 hardware transcoding works on newer Radeon GPUs** that
Plex's bundled driver doesn't recognize.

Built and published automatically on top of the **latest** `linuxserver/plex` every day.

```
ghcr.io/panarican/plex-amd-vaapi:latest      # public/GA Plex channel
ghcr.io/panarican/plex-amd-vaapi:plexpass    # Plex Pass beta channel
```

## The problem this solves

Plex ships an old Mesa `radeonsi` VAAPI driver that only recognizes **gfx1100–gfx1103**.
On newer AMD APUs/GPUs the GPU is detected by the OS (`vainfo` works) but Plex's bundled
driver fails to initialize it, so hardware transcoding silently falls back to CPU. Affected
hardware includes:

- **Strix Point** — Radeon 880M/890M (**gfx1150**)
- **Strix Halo** — Ryzen AI MAX, Radeon 8050S/8060S (**gfx1151**)
- and other GPUs newer than Plex's bundled driver

This image injects a current, **self-contained musl Mesa `radeonsi` driver** (from Alpine)
plus a matching `libva`, and wires Plex's transcoder + capability probe to use it — so
**AMD H.264 hardware transcoding works**.

> **Verified on Strix Halo** (Radeon 8060S, `gfx1151`): the injected bundle loads as
> `Mesa Gallium 25.1.9 / LLVM 20.1.8`, initializes VAAPI, and H.264 hardware-encodes through
> Plex's transcoder. The Mesa version tracks Alpine's `mesa-va-gallium`, so it advances
> automatically with every rebuild — no version is pinned in this repo.

## ⚠️ What this does NOT do — HEVC encode

It does **not** unlock HEVC/H.265 hardware **encoding**. Plex deliberately gates HEVC
hardware encode to **Intel QuickSync, NVIDIA NVENC, and Apple VideoToolbox** and excludes
AMD VAAPI — Plex's own docs state verbatim *"(AMD is not supported)"*. The `hevc_vaapi`
encoder exists in Plex's ffmpeg and AMD silicon can do HEVC encode, but Plex's
capability/decision layer refuses it on AMD regardless of driver. No server-side change
fixes this; it needs Plex to add AMD support (Plex staff have said this is unimplemented
and gated behind an FFmpeg 6.1 transcoder rework, with Intel prioritized first).

**For your AMD HEVC *content*, enable Direct Play** in the Plex client — capable devices
decode the original HEVC untouched (best quality, no transcode).

## Usage (docker-compose)

```yaml
services:
  plex:
    image: ghcr.io/panarican/plex-amd-vaapi:latest
    container_name: plex
    restart: unless-stopped
    network_mode: host
    environment:
      - TZ=America/New_York
      - PUID=1000
      - PGID=1000
      - VERSION=docker          # use the Plex baked into the image; update by pulling a new image
    group_add:
      - "44"   # video  (use your host's render/video GIDs)
      - "105"  # render
    devices:
      - /dev/dri:/dev/dri       # AMD GPU (VAAPI)
    volumes:
      - ./config:/config
      - /path/to/media:/media:ro
```

Adjust `group_add` to your host's `render`/`video` group IDs (`getent group render video`).
Already-claimed Plex configs migrate in place — do **not** set `PLEX_CLAIM` on an existing
server (it can blank the token).

### Verify hardware transcoding

Play something that transcodes, then check **Dashboard → Now Playing** for "(hw)", or:

```bash
docker exec plex bash -c 'for p in /proc/[0-9]*/cmdline; do tr "\0" " " <$p; echo; done' \
  | grep -i 'Transcoder' | grep -oE 'h264_vaapi|hwaccel vaapi'
```

## How updates work

The GitHub Action rebuilds this image on the **latest** `linuxserver/plex` daily, re-applying
the driver layers, and pushes `:latest`. Pull to update:

```bash
docker compose pull plex && docker compose up -d plex
```

(or use [Watchtower](https://containrrr.dev/watchtower/) to auto-pull). When Plex eventually
adds AMD HEVC encode support, a normal pull picks it up.

### Plex Pass channel

`linuxserver/plex:latest` only ever bundles the **public** PMS release — Plex Pass beta
builds require an authenticated account check that LinuxServer's own public CI can't do.
This repo's workflow can instead install the current **plexpass**-channel release before
applying the driver layers, published as `:plexpass`.

This needs a `PLEX_TOKEN` repo secret (your Plex account token). Set it yourself so it
never appears in chat/shell history:

```bash
gh secret set PLEX_TOKEN --repo panarican/plex-amd-vaapi
```

The token is only ever mounted into the build via a BuildKit secret (`--mount=type=secret`),
never a build-arg or `ENV`, so it can't end up baked into the published image's layers or
`docker history` — this repo/image is public. Without the secret set, the `plexpass` build
leg just fails (the `public`/`:latest` build is unaffected — `fail-fast: false`).

## How it works (internals)

1. **Stage 1** builds a self-contained musl Mesa `radeonsi` driver bundle from `alpine:3.22`
   (current Mesa — `25.1.9` at the time of writing) including its full dependency closure + a matching `libva`.
2. **Stage 2** layers it onto `lscr.io/linuxserver/plex:latest`, wraps `Plex Transcoder` so
   each transcode uses the injected driver, and prepends the VAAPI env to the `svc-plex` s6
   run script so Plex's in-process capability probe uses it too.

Because the driver is **baked into the image** (not fetched at runtime), there's no
dependency on an external mod registry staying online.

## Credits

Inspired by the VAAPI-injection approach pioneered in
[jefflessard/plex-vaapi-amdgpu-mod](https://github.com/jefflessard/plex-vaapi-amdgpu-mod)
and discussed in the Plex forums. This image rebuilds the driver from current Alpine Mesa
and bakes it in for self-containment + automated rebuilds.

## License

MIT — see [LICENSE](LICENSE).
