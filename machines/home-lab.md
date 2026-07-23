# home-lab — Ubuntu home server

> You are on **home-lab**, a repurposed 2015 MacBook Pro 15" running
> Ubuntu 24.04 LTS headless. i7-4770HQ (4c/8t, Intel QSV), **16GB RAM**.
> This is Marcos's first Linux box — explain Linux-isms when relevant.

## Network

- LAN `192.168.1.143`, static via netplan matching the Thunderbolt→GbE adapter
  **by MAC** (renamed `lan0`). Don't "fix" the interface name.
- Reached from the Macs as `ssh homelab` (user `home-lab`, in sudo + docker groups)

## Services (all Docker, `restart: unless-stopped`, compose in ~/services/<name>/)

- **Jellyfin** :8096 (family media) + **Jellyfin-Private** :8097 (separate config/users)
- **Pi-hole** :80 (host networking; the server itself still resolves via 8.8.8.8)
- **Jellyseerr** :5055 (media requests)
- **Immich** :2283 (photos; postgres+redis+ML containers; ~22k assets)
- **Dashboard** :8888 (read-only status page; Glances API on :61208 feeds it)
- **Arr stack**: qBittorrent :8701 (ONLY container behind Gluetun VPN),
  Radarr :7878, Sonarr :8989, Prowlarr :9696, FlareSolverr :8191
- **jellyfin-organize** — systemd service (not Docker), inotify watcher that
  sorts new files into `Films/` and `Shows/` structures
- **Samba** — `[media]` share of /mnt/media for the Macs

## Storage (both drives `nofail` in fstab)

- `/mnt/media` — WD Red Plus 4TB, **ext4** (hard links work — Arr stack relies
  on this for downloads→library linking)
- `/mnt/hgst` — HGST 4TB USB HDD: Immich uploads (`/mnt/hgst/immich`),
  Google Takeout archive, personal media

## Hard-won gotchas

- **Immich ML job concurrency ceiling is 2.** At 3+ the server container gets
  OOM-killed (16GB) and the USB HDD thrashes (load ~100, all I/O wait). The
  bottleneck is HDD+RAM, not GPU.
- Docker 29 rejects versioned API paths on the socket (`/v1.24/...`) — use unversioned.
- A CUDA ML worker on VENGEANCE (`192.168.1.156:3003`) can be added in Immich
  Admin → ML Settings for big backlogs; it's temporary, don't assume it's up.
- Glances must be the pipx v4 install (`glances.service`), NOT the apt v3 package.

## Where the full docs live

The complete runbook (per-service details, guides, PRDs) is
`~/roaming/projects/home-lab/` **on the Macs** — notably its `CLAUDE.md`.
This box only has this facts file; ask the user or check from a Mac for depth.
