# kaged-releases

Distribution artifacts, install scripts, and reference configs for [kaged](https://github.com/kaged-dev).

## Quick start (binary)

```bash
curl -fsSL https://raw.githubusercontent.com/kaged-dev/kaged-releases/main/install.sh | bash
```

The installer asks a few questions, defaults to the shared SSO relay and shared UI, and sets up a systemd unit.

```bash
# Or be explicit about everything:
curl -fsSL https://raw.githubusercontent.com/kaged-dev/kaged-releases/main/install.sh | bash -s -- --user --no-sso --no-shared-ui
```

## Docker install

```bash
curl -fsSL https://raw.githubusercontent.com/kaged-dev/kaged-releases/main/install-docker.sh | bash
```

Or manually:

```bash
docker pull ghcr.io/kaged-dev/kaged-daemon:latest
```

## Container image

```
ghcr.io/kaged-dev/kaged-daemon:latest
ghcr.io/kaged-dev/kaged-daemon:v0.1.0
```

Ports: `13000` (daemon HTTP+WS).
Volumes: `/data` (SQLite + state), `/config` (local.toml).

## What's here

- **install.sh** — Binary installer. Downloads the latest per-arch release, verifies the checksum, installs the `kaged` daemon, writes a config, and wires up systemd.
- **install-docker.sh** — Docker MVP installer. Pulls the image, writes a compose file, installs the `kaged` wrapper.
- **kaged** — Thin CLI wrapper that fronts the containerised daemon.
- **systemd/** — Reference systemd unit files for system-wide and per-user deployments.
- **config.*.toml** — Example daemon configs.
  - `config.shared.toml` — Uses the shared SSO relay and shared UI at `kaged.dev`.
  - `config.minimal.toml` — Serves the bundled UI locally, no shared services.
  - `config.user.toml` — Per-user XDG paths, bundled UI.
- **GitHub Releases** — Per-arch binaries + SHA256SUMS.

## Reference configs

Copy the example that matches your deployment and edit paths as needed:

```bash
sudo mkdir -p /etc/kaged
sudo cp config.shared.toml /etc/kaged/config.toml
sudo systemctl restart kaged
```

## systemd units

- `systemd/kaged.service` — System-wide unit. Runs as a dedicated `kaged` user with systemd hardening.
- `systemd/kaged-user.service` — Per-user unit. Runs in your own systemd user session.

See the [daemon spec](https://github.com/kaged-dev/kaged/blob/main/docs/specs/daemon.md#systemd-units) for full notes.

## kaged wrapper (Docker only)

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

[Pre-Release Evaluation License](LICENCE.md)
