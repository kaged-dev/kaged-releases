#!/usr/bin/env bash
set -euo pipefail

KAGED_IMAGE="${KAGED_IMAGE:-ghcr.io/kaged-dev/kaged-daemon:latest}"
KAGED_PORT="${KAGED_PORT:-13000}"
KAGED_DIR="${KAGED_DIR:-$HOME/.kaged}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

main() {
  check_docker
  pull_image
  write_compose
  install_wrapper
  echo ""
  echo "kaged installed."
  echo "  Config: $KAGED_DIR"
  echo "  Wrapper: $INSTALL_DIR/kaged"
  echo ""
  echo "Start with: kaged start"
  echo "Then:       kaged auth launch"
}

check_docker() {
  if ! command -v docker &>/dev/null; then
    echo "Error: docker not found. Install Docker first." >&2
    exit 1
  fi
  if ! docker compose version &>/dev/null; then
    echo "Error: docker compose (v2) not found." >&2
    exit 1
  fi
}

pull_image() {
  echo "Pulling $KAGED_IMAGE..."
  docker pull "$KAGED_IMAGE"
}

write_compose() {
  mkdir -p "$KAGED_DIR"
  cat > "$KAGED_DIR/compose.yaml" <<YAML
services:
  kaged:
    image: ${KAGED_IMAGE}
    container_name: kaged
    restart: unless-stopped
    ports:
      - "${KAGED_PORT}:13000"
    volumes:
      - kaged-data:/data
      - kaged-config:/config
    environment:
      - KAGED_PUBLIC_URL=http://localhost:${KAGED_PORT}

volumes:
  kaged-data:
  kaged-config:
YAML
  echo "Wrote $KAGED_DIR/compose.yaml"
}

install_wrapper() {
  mkdir -p "$INSTALL_DIR"

  local src
  src="$(cd "$(dirname "$0")" && pwd)/kaged"
  if [ -f "$src" ]; then
    cp "$src" "$INSTALL_DIR/kaged"
  else
    curl -fsSL "https://raw.githubusercontent.com/kaged-dev/kaged-releases/main/kaged" \
      -o "$INSTALL_DIR/kaged"
  fi
  chmod +x "$INSTALL_DIR/kaged"

  if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
    echo ""
    echo "Add to your shell profile:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
  fi
}

main "$@"
