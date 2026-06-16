#!/usr/bin/env bash
# shellcheck disable=SC3043
set -euo pipefail

# kaged installer — downloads the latest release binary, installs it, writes a
# config, and wires up systemd. Interactive by default; flags make it silent.

REPO="kaged-dev/kaged-releases"
RELEASES_API="https://api.github.com/repos/${REPO}/releases/latest"
RELEASES_HTML="https://github.com/${REPO}/releases"

SYSTEM_MODE="${SYSTEM_MODE:-}"
NO_SSO="${NO_SSO:-}"
NO_SHARED_UI="${NO_SHARED_UI:-}"
SKIP_SYSTEMD="${SKIP_SYSTEMD:-}"
BIN_DIR="${BIN_DIR:-}"
CONFIG_DIR="${CONFIG_DIR:-}"
HOME_DIR="${HOME_DIR:-}"
NONINTERACTIVE="${NONINTERACTIVE:-}"

RED='\033[0;31m'
AMBER='\033[0;33m'
MAGENTA='\033[0;35m'
DIM='\033[0;37m'
RESET='\033[0m'
BOLD='\033[1m'

say() {
  printf "${AMBER}[kaged]${RESET} %s\n" "$*"
}

curse() {
  printf "${MAGENTA}[kaged]${RESET} ${BOLD}%s${RESET}\n" "$*"
}

whisper() {
  printf "${DIM}[kaged]${RESET} %s\n" "$*"
}

warn() {
  printf "${RED}[kaged]${RESET} %s\n" "$*" >&2
}

die() {
  warn "$*"
  exit 1
}

parse_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --user)
        SYSTEM_MODE="user"
        ;;
      --system)
        SYSTEM_MODE="system"
        ;;
      --no-sso)
        NO_SSO="1"
        ;;
      --no-shared-ui)
        NO_SHARED_UI="1"
        ;;
      --skip-systemd)
        SKIP_SYSTEMD="1"
        ;;
      --bin-dir)
        BIN_DIR="$2"
        shift
        ;;
      --config-dir)
        CONFIG_DIR="$2"
        shift
        ;;
      --home-dir)
        HOME_DIR="$2"
        shift
        ;;
      -y|--yes)
        NONINTERACTIVE="1"
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        die "Unknown flag: $1 (try --help)"
        ;;
    esac
    shift
  done
}

show_help() {
  cat <<'EOF'
Install kaged from the latest GitHub release.

Flags:
  --user              Install for the current user only (~/.local/bin).
  --system            Install globally with sudo (/usr/local/bin).
  --no-sso            Do not enable shared SSO in the generated config.
  --no-shared-ui      Do not point the daemon at the shared UI.
  --skip-systemd      Do not create or enable a systemd unit.
  --bin-dir PATH      Override the binary install directory.
  --config-dir PATH   Override the daemon config directory.
  --home-dir PATH     Override the daemon state directory.
  -y, --yes           Non-interactive; accept defaults.
  -h, --help          Show this message.

Defaults:
  Global install, systemd enabled, shared SSO on, shared UI on.
EOF
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer

  if [ "$NONINTERACTIVE" = "1" ]; then
    case "$default" in
      [Yy]) return 0 ;;
      *) return 1 ;;
    esac
  fi

  while true; do
    if [ "$default" = "y" ]; then
      printf "%s [Y/n] " "$prompt"
    else
      printf "%s [y/N] " "$prompt"
    fi
    read -r answer
    case "${answer:-$default}" in
      [Yy]*)
        return 0
        ;;
      [Nn]*)
        return 1
        ;;
    esac
  done
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64)
      echo "linux-x64"
      ;;
    aarch64|arm64)
      echo "linux-arm64"
      ;;
    *)
      die "Unsupported architecture: $machine. kaged releases only ship linux-x64 and linux-arm64 binaries."
      ;;
  esac
}

require_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    die "curl is required. Install it first."
  fi
}

require_systemd() {
  if [ "$SKIP_SYSTEMD" = "1" ]; then
    return 0
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found. Skipping systemd setup."
    SKIP_SYSTEMD="1"
  fi
}

fetch_latest_release() {
  local arch="$1"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  whisper "Checking GitHub Releases for the latest ${arch} binary..."
  local release_json
  if ! release_json="$(curl -fsSL --retry 3 --retry-delay 1 "$RELEASES_API")"; then
    die "Could not fetch latest release metadata from ${RELEASES_API}. Are you rate-limited?"
  fi

  local tag
  tag="$(printf '%s\n' "$release_json" | grep -o '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4)"
  if [ -z "$tag" ]; then
    die "Could not parse tag_name from GitHub release response."
  fi

  local asset_name="kaged-${arch}"
  local asset_url
  asset_url="$(printf '%s\n' "$release_json" | grep -o '"browser_download_url": *"[^"]*'"$asset_name"'"' | head -n1 | cut -d'"' -f4)"
  if [ -z "$asset_url" ]; then
    asset_name="kaged-linux-${arch#*-}"
    asset_url="$(printf '%s\n' "$release_json" | grep -o '"browser_download_url": *"[^"]*'"$asset_name"'"' | head -n1 | cut -d'"' -f4)"
  fi
  if [ -z "$asset_url" ]; then
    asset_name="kaged"
    asset_url="$(printf '%s\n' "$release_json" | grep -o '"browser_download_url": *"[^"]*'"$asset_name"'"' | head -n1 | cut -d'"' -f4)"
  fi

  if [ -z "$asset_url" ]; then
    die "Could not find a ${arch} binary in release ${tag}. See ${RELEASES_HTML}"
  fi

  local sums_url
  sums_url="$(printf '%s\n' "$release_json" | grep -o '"browser_download_url": *"[^"]*SHA256SUMS"' | head -n1 | cut -d'"' -f4)"

  echo "$tag"
  echo "$asset_url"
  echo "$sums_url"
  echo "$tmpdir"
  echo "$asset_name"
}

download_and_verify() {
  local tag="$1"
  local asset_url="$2"
  local sums_url="$3"
  local tmpdir="$4"
  local arch="$5"
  local asset_name="$6"

  local bin_path="${tmpdir}/kaged"
  local sums_path="${tmpdir}/SHA256SUMS"

  say "Downloading ${asset_name} (${tag})..."
  curl -fsSL --retry 3 --retry-delay 1 --progress-bar "$asset_url" -o "$bin_path"

  if [ -n "$sums_url" ]; then
    say "Downloading SHA256SUMS..."
    curl -fsSL --retry 3 --retry-delay 1 "$sums_url" -o "$sums_path"
    whisper "Verifying checksum..."
    if ! grep -q "^[^#]*${asset_name}[[:space:]]" "$sums_path"; then
      warn "${asset_name} not found in SHA256SUMS; skipping checksum verification."
    elif command -v sha256sum >/dev/null 2>&1; then
      if ! (cd "$tmpdir" && grep "${asset_name}[[:space:]]" "$sums_path" | sha256sum -c --quiet - 2>/dev/null); then
        die "Checksum verification failed for ${asset_name}."
      fi
    elif command -v shasum >/dev/null 2>&1; then
      local expected
      expected="$(grep "${asset_name}" "$sums_path" | awk '{print $1}')"
      local actual
      actual="$(shasum -a 256 "$bin_path" | awk '{print $1}')"
      if [ "$expected" != "$actual" ]; then
        die "Checksum mismatch for ${asset_name}."
      fi
    else
      warn "No SHA256 verification tool available; skipping checksum."
    fi
  else
    warn "No SHA256SUMS found in release; skipping checksum verification."
  fi

  echo "$bin_path"
}

resolve_install_mode() {
  if [ -z "$SYSTEM_MODE" ]; then
    if ! ask_yes_no "Install globally with sudo? (no = user-only install)" "y"; then
      SYSTEM_MODE="user"
    else
      SYSTEM_MODE="system"
    fi
  fi

  if [ "$SYSTEM_MODE" = "system" ]; then
    BIN_DIR="${BIN_DIR:-/usr/local/bin}"
    CONFIG_DIR="${CONFIG_DIR:-/etc/kaged}"
    HOME_DIR="${HOME_DIR:-/var/lib/kaged}"
    SUDO="${SUDO:-sudo}"
    if [ "$(id -u)" -eq 0 ]; then
      SUDO=""
    fi
  else
    BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
    CONFIG_DIR="${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/kaged}"
    HOME_DIR="${HOME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/kaged}"
    SUDO=""
  fi
}

write_config() {
  local config_dir="$1"
  local home_dir="$2"
  local sso_enabled="$3"
  local shared_ui_enabled="$4"

  local config_path="${config_dir}/config.toml"

  if [ -f "$config_path" ]; then
    if ask_yes_no "${config_path} already exists. Overwrite?" "n"; then
      whisper "Backing up existing config to ${config_path}.bak"
      if [ -n "$SUDO" ]; then
        $SUDO cp "$config_path" "${config_path}.bak"
      else
        cp "$config_path" "${config_path}.bak"
      fi
    else
      whisper "Skipping config write; existing config left untouched."
      return
    fi
  fi

  local bind
  if [ "$SYSTEM_MODE" = "system" ]; then
    bind="127.0.0.1:7777"
  else
    bind="127.0.0.1:0"
  fi

  local ui_serve="true"
  local ui_url=""
  if [ "$shared_ui_enabled" = "1" ]; then
    ui_serve="false"
    ui_url="https://ui.kaged.dev"
  fi

  local sso_block=""
  if [ "$sso_enabled" = "1" ]; then
    sso_block="

[auth.sharedsso]
enabled = true
issuer = \"https://sso.kaged.dev\"
public_key = \"\"\"-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEOfnlB+9LXaT4Z5AvNz26gxpm955Z
WvlAtVvF4e5j+GkXePkg9G4DDrbUGBx0H+/w7OnG9jndtwg4T4Y/gyAezw==
-----END PUBLIC KEY-----\"\"\"
user_creation = \"enabled\"
pending_ttl_days = 7"
  fi

  local config_body
  config_body="# kaged daemon configuration
# Generated by the kaged installer. Edit freely; restart the daemon to apply.

[daemon]
bind = \"${bind}\"
home = \"${home_dir}\"
public_url = \"\"

[auth]
mode = \"secure\"${sso_block}

[storage]
url = \"sqlite://${home_dir}/kaged.db\"

[sandbox]
mode = \"enabled\"
default_seccomp = \"default\"

[logging]
operational = \"stderr\"
audit = \"file:${home_dir}/audit.log\"
level = \"info\"

[plugins]
dir = \"${home_dir}/plugins\"
enabled = []

[ui]
serve = ${ui_serve}
url = \"${ui_url}\"
"

  whisper "Writing config to ${config_path}"
  if [ -n "$SUDO" ]; then
    $SUDO mkdir -p "$config_dir"
    $SUDO tee "$config_path" >/dev/null <<EOF
${config_body}
EOF
    $SUDO chmod 644 "$config_path"
  else
    mkdir -p "$config_dir"
    cat > "$config_path" <<EOF
${config_body}
EOF
    chmod 644 "$config_path"
  fi
}

install_binary() {
  local src_path="$1"
  local dest="${BIN_DIR}/kaged"

  if [ -f "$dest" ]; then
    if ! ask_yes_no "${dest} already exists. Replace it?" "y"; then
      die "Install aborted."
    fi
  fi

  say "Installing kaged to ${dest}..."
  if [ -n "$SUDO" ]; then
    $SUDO mkdir -p "$BIN_DIR"
    $SUDO cp "$src_path" "$dest"
    $SUDO chmod 755 "$dest"
  else
    mkdir -p "$BIN_DIR"
    cp "$src_path" "$dest"
    chmod 755 "$dest"
  fi
}

install_systemd_service() {
  if [ "$SKIP_SYSTEMD" = "1" ]; then
    return 0
  fi

  local service_name="kaged.service"
  local service_path

  if [ "$SYSTEM_MODE" = "system" ]; then
    service_path="/etc/systemd/system/${service_name}"
    if [ -n "$SUDO" ]; then
      $SUDO mkdir -p /etc/systemd/system
    fi
  else
    service_path="${HOME}/.config/systemd/user/${service_name}"
    mkdir -p "${HOME}/.config/systemd/user"
  fi

  if [ -f "$service_path" ]; then
    if ! ask_yes_no "${service_path} already exists. Overwrite?" "y"; then
      whisper "Skipping systemd service."
      return 0
    fi
  fi

  local config_flag
  if [ "$SYSTEM_MODE" = "system" ]; then
    config_flag="/etc/kaged/config.toml"
  else
    config_flag="${CONFIG_DIR}/config.toml"
  fi

  local service_body
  if [ "$SYSTEM_MODE" = "system" ]; then
    service_body="[Unit]
Description=kaged daemon
After=network.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/kaged start --config=${config_flag}
Restart=on-failure
RestartSec=5
Environment=KAGED_CONFIG=${config_flag}

[Install]
WantedBy=multi-user.target"
  else
    service_body="[Unit]
Description=kaged daemon (user)
After=network.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/kaged start --config=${config_flag}
Restart=on-failure
RestartSec=5
Environment=KAGED_CONFIG=${config_flag}

[Install]
WantedBy=default.target"
  fi

  say "Installing systemd service to ${service_path}..."
  if [ -n "$SUDO" ]; then
    $SUDO tee "$service_path" >/dev/null <<EOF
${service_body}
EOF
    $SUDO chmod 644 "$service_path"
    $SUDO systemctl daemon-reload
    if ask_yes_no "Enable and start kaged.service now?" "y"; then
      $SUDO systemctl enable kaged.service
      $SUDO systemctl start kaged.service
    fi
  else
    cat > "$service_path" <<EOF
${service_body}
EOF
    chmod 644 "$service_path"
    systemctl --user daemon-reload
    if ask_yes_no "Enable and start kaged.service (user) now?" "y"; then
      systemctl --user enable kaged.service
      systemctl --user start kaged.service
    fi
  fi
}

advise_path() {
  if [ "$SYSTEM_MODE" = "system" ]; then
    return 0
  fi
  case ":${PATH}:" in
    *":${BIN_DIR}:"*)
      return 0
      ;;
  esac
  warn "${BIN_DIR} is not on your PATH."
  warn "Add this to your shell profile:"
  warn "  export PATH=\"${BIN_DIR}:\$PATH\""
}

main() {
  parse_flags "$@"
  require_curl
  require_systemd

  curse "kaged installer // one binary, one config, one daemon."
  echo ""

  resolve_install_mode
  local arch
  arch="$(detect_arch)"

  say "Target: ${arch} | Mode: ${SYSTEM_MODE} | Bin: ${BIN_DIR}"
  echo ""

  local release_info
  release_info="$(fetch_latest_release "$arch")"
  local tag asset_url sums_url tmpdir asset_name
  tag="$(printf '%s\n' "$release_info" | sed -n '1p')"
  asset_url="$(printf '%s\n' "$release_info" | sed -n '2p')"
  sums_url="$(printf '%s\n' "$release_info" | sed -n '3p')"
  tmpdir="$(printf '%s\n' "$release_info" | sed -n '4p')"
  asset_name="$(printf '%s\n' "$release_info" | sed -n '5p')"
  trap 'rm -rf "$tmpdir"' EXIT

  local bin_path
  bin_path="$(download_and_verify "$tag" "$asset_url" "$sums_url" "$tmpdir" "$arch" "$asset_name")"

  echo ""
  if [ -z "$NO_SSO" ] && ! ask_yes_no "Enable shared SSO (sso.kaged.dev) for convenience?" "y"; then
    NO_SSO="1"
  fi
  if [ -z "$NO_SHARED_UI" ] && ! ask_yes_no "Use the shared UI (ui.kaged.dev) instead of serving the UI locally?" "y"; then
    NO_SHARED_UI="1"
  fi
  if [ -z "$SKIP_SYSTEMD" ] && ! ask_yes_no "Create and enable a systemd service?" "y"; then
    SKIP_SYSTEMD="1"
  fi

  echo ""
  install_binary "$bin_path"
  write_config "$CONFIG_DIR" "$HOME_DIR" "${NO_SSO:-0}" "${NO_SHARED_UI:-0}"
  install_systemd_service

  echo ""
  say "kaged ${tag} installed."
  whisper "  binary: ${BIN_DIR}/kaged"
  whisper "  config: ${CONFIG_DIR}/config.toml"
  whisper "  state:  ${HOME_DIR}"
  if [ "$SKIP_SYSTEMD" != "1" ]; then
    if [ "$SYSTEM_MODE" = "system" ]; then
      whisper "  service: systemctl status kaged.service"
    else
      whisper "  service: systemctl --user status kaged.service"
    fi
  fi
  echo ""
  curse "Run it. Own it. Don't expose it to the internet."
  echo ""

  advise_path
}

main "$@"
