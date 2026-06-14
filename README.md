# kaged-releases

Distribution artifacts and install scripts for [kaged](https://github.com/kaged-dev/kaged).

## Quick start (Docker)

```bash
curl -fsSL https://raw.githubusercontent.com/kaged-dev/kaged-releases/main/install.sh | bash
```

Or manually:

```bash
docker pull ghcr.io/kaged-dev/kaged-daemon:latest
```

## What's here

- **install.sh** — Docker MVP installer. Pulls the image, writes a compose file, installs the `kaged` wrapper.
- **kaged** — Thin CLI wrapper that fronts the containerised daemon.
- **GitHub Releases** — Per-arch binaries + SHA256SUMS, published by the monorepo release CI.

## Container image

```
ghcr.io/kaged-dev/kaged-daemon:latest
ghcr.io/kaged-dev/kaged-daemon:v0.1.0
```

Ports: `13000` (daemon HTTP+WS).
Volumes: `/data` (SQLite + state), `/config` (local.toml).

## kaged wrapper

```bash
kaged start              # docker compose up -d
kaged stop               # docker compose down
kaged status             # docker compose ps
kaged auth launch        # open the daemon UI in browser
kaged logs               # docker compose logs -f
kaged update             # pull latest + restart
kaged exec <cmd>         # docker exec into the container
```

## License

To be decided. See the [monorepo](https://github.com/kaged-dev/kaged).
