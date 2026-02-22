#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Raspberry Pi Homelab Bootstrap (idempotent)
#
# Goal:
#   After a fresh OS install / reformat, run this script to:
#     - Install Docker (if missing) and ensure the daemon is running
#     - Install Tailscale (if missing) and ensure it is connected
#     - Write homelab .env with TS_IP / TS_FQDN (only if it actually changed)
#     - Ensure the certs directory exists and explain expected filenames
#     - Start/update the Docker Compose stack
#
# Safe to re-run:
#   This script is designed to be idempotent. Re-running it should:
#     - skip work that's already done
#     - only change files when the content needs to change
#     - keep services running
#
# Optional non-interactive Tailscale login:
#   If you want this to be fully headless/unattended, export an auth key:
#     export TAILSCALE_AUTH_KEY="tskey-auth-..."
#   Then run the script. If not provided, it will run `tailscale up` interactively.
###############################################################################

# You can override this when invoking the script:
#   HOMELAB_DIR=/srv/homelab ./bootstrap.sh
HOMELAB_DIR="${HOMELAB_DIR:-$HOME/homelab}"
ENV_FILE="$HOMELAB_DIR/.env"
CERTS_DIR="$HOMELAB_DIR/config/certs"

# Print helpers (clear + consistent output)
step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Decide whether we need sudo.
# - If running as root: sudo is not needed.
# - If not root: sudo must exist, and we will use it for privileged operations.
SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  command_exists sudo || die "This script needs root privileges. Install sudo or run as root."
  SUDO="sudo"
fi

# apt helpers: only run `apt-get update` if we actually need to install something.
APT_UPDATED=0
apt_update_once() {
  if [[ "$APT_UPDATED" -eq 0 ]]; then
    step "Updating apt package index"
    $SUDO apt-get update -y
    APT_UPDATED=1
  fi
}

apt_install_if_missing() {
  command_exists apt-get || die "apt-get not found. This script assumes Debian/Ubuntu/Raspberry Pi OS."

  local missing=()
  local pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    step "Installing packages: ${missing[*]}"
    apt_update_once
    $SUDO apt-get install -y "${missing[@]}"
  fi
}

# Write a file only if the content actually changed.
# This avoids unnecessary churn (and is friendlier to config management habits).
write_file_if_changed() {
  local path="$1"
  local content="$2"

  local tmp
  tmp="$(mktemp)"
  printf '%s' "$content" > "$tmp"

  # Ensure parent directory exists.
  mkdir -p "$(dirname "$path")"

  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    step "No change: $(basename "$path") is already up to date"
    return 0
  fi

  step "Writing: $path"
  mv "$tmp" "$path"
}

# Ensure a systemd service is enabled + running (if systemctl exists).
ensure_service_running() {
  local service="$1"

  if ! command_exists systemctl; then
    warn "systemctl not found; cannot auto-manage service: $service"
    return 0
  fi

  if ! $SUDO systemctl is-enabled --quiet "$service" 2>/dev/null; then
    step "Enabling service: $service"
    $SUDO systemctl enable "$service"
  fi

  if ! $SUDO systemctl is-active --quiet "$service" 2>/dev/null; then
    step "Starting service: $service"
    $SUDO systemctl start "$service"
  fi
}

###############################################################################
# 0) Sanity checks
###############################################################################
step "Checking homelab directory exists: $HOMELAB_DIR"
[[ -d "$HOMELAB_DIR" ]] || die "Missing $HOMELAB_DIR. (Clone/copy your homelab repo there first.)"

# We use curl and jq for predictable installs + JSON parsing.
apt_install_if_missing curl ca-certificates jq

###############################################################################
# 1) Docker install + daemon running + Compose availability
###############################################################################
if ! command_exists docker; then
  step "Docker not found. Installing Docker via official convenience script"
  # The official script sets up Docker's repo and installs engine + related packages.
  curl -fsSL https://get.docker.com | $SUDO sh
else
  step "Docker already installed: $(docker --version)"
fi

# Make sure Docker is running
ensure_service_running docker

# Ensure the docker group exists (it should after Docker install, but this makes it explicit)
if ! getent group docker >/dev/null 2>&1; then
  step "Creating 'docker' group"
  $SUDO groupadd docker
fi

# Add current user to docker group if needed (so docker commands can run without sudo in future sessions)
if [[ "${EUID}" -ne 0 ]]; then
  if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    step "User '$USER' is already in the docker group"
  else
    step "Adding user '$USER' to the docker group"
    $SUDO usermod -aG docker "$USER"
    warn "Group membership changes require a logout/login (or reboot) to take effect."
  fi
fi

# Decide how we'll run docker for THIS execution:
# - Prefer non-sudo docker (cleaner)
# - Fall back to sudo docker if permissions aren't active yet (first run scenario)
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  if [[ -n "$SUDO" ]]; then
    DOCKER=($SUDO docker)
    warn "Docker requires sudo in this session (likely because docker group membership isn't active yet)."
  else
    die "Docker is installed but cannot access the daemon (and sudo is unavailable)."
  fi
fi

# Prefer `docker compose` plugin (modern). If missing, try to install it.
if ! docker compose version >/dev/null 2>&1; then
  step "Docker Compose plugin not detected. Installing docker-compose-plugin"
  apt_install_if_missing docker-compose-plugin
fi

# Compose command (as an array so sudo wrapper stays intact)
COMPOSE=("${DOCKER[@]}" compose)
"${COMPOSE[@]}" version >/dev/null 2>&1 || die "Docker Compose is still unavailable. Check Docker installation."

###############################################################################
# 2) Tailscale install + connected
###############################################################################
if ! command_exists tailscale; then
  step "Tailscale not found. Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | $SUDO sh
else
  step "Tailscale already installed: $(tailscale version | head -n1 || true)"
fi

# Ensure tailscaled is running
ensure_service_running tailscaled

# Determine whether Tailscale is already connected.
# We consider it "connected" when BackendState is "Running".
TS_BACKEND_STATE="$(
  tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' || true
)"

if [[ "$TS_BACKEND_STATE" != "Running" ]]; then
  step "Tailscale is not connected (BackendState: ${TS_BACKEND_STATE:-unknown})"

  if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
    step "Connecting Tailscale using TAILSCALE_AUTH_KEY (non-interactive)"
    $SUDO tailscale up --auth-key="$TAILSCALE_AUTH_KEY"
  else
    step "Connecting Tailscale interactively (you may get a login URL)"
    $SUDO tailscale up
    warn "If you were shown a login URL, open it to authenticate this device."
  fi
else
  step "Tailscale already connected"
fi

###############################################################################
# 3) Read Tailscale IP + FQDN (MagicDNS), write .env
###############################################################################
step "Reading Tailscale identity (IP + DNS name)"

TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
TS_FQDN="$(
  tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//' || true
)"

# Fail early with clear guidance. Your stack expects these values.
[[ -n "$TS_IP" ]]   || die "Could not determine Tailscale IPv4 address. Is Tailscale connected?"
[[ -n "$TS_FQDN" ]] || die "Could not determine Tailscale DNS name. Ensure MagicDNS is enabled in Tailscale."

step "Tailscale IP:  $TS_IP"
step "Tailscale DNS: $TS_FQDN"

ENV_CONTENT=$(
  cat <<EOF
TS_IP=${TS_IP}
TS_FQDN=${TS_FQDN}
EOF
)

write_file_if_changed "$ENV_FILE" "$ENV_CONTENT"

###############################################################################
# 4) Certs directory + expectations
###############################################################################
step "Ensuring certs directory exists: $CERTS_DIR"
mkdir -p "$CERTS_DIR"

EXPECTED_CRT="$CERTS_DIR/${TS_FQDN}.crt"
EXPECTED_KEY="$CERTS_DIR/${TS_FQDN}.key"

if [[ ! -s "$EXPECTED_CRT" || ! -s "$EXPECTED_KEY" ]]; then
  warn "TLS certs not found (or empty). HTTPS will not work until these exist:"
  echo "  - $EXPECTED_CRT"
  echo "  - $EXPECTED_KEY"
  echo ""
  echo "HTTP on port 80 can still work (depending on your Compose stack)."
fi

###############################################################################
# 5) Start / update the Compose stack
###############################################################################
step "Starting (or updating) services via Docker Compose"

# Fail fast if the directory doesn't look like a Compose project
if [[ ! -f "$HOMELAB_DIR/docker-compose.yml" && \
      ! -f "$HOMELAB_DIR/docker-compose.yaml" && \
      ! -f "$HOMELAB_DIR/compose.yml" && \
      ! -f "$HOMELAB_DIR/compose.yaml" ]]; then
  die "No Compose file found in $HOMELAB_DIR (expected docker-compose.yml / compose.yml)."
fi

(
  cd "$HOMELAB_DIR"

  # Pull first so fresh installs always get images without needing a second run.
  "${COMPOSE[@]}" pull

  # Up is idempotent: creates what's missing, updates what's changed.
  "${COMPOSE[@]}" up -d --remove-orphans
)

###############################################################################
# Done
###############################################################################
step "Setup complete. Quick links (assuming your reverse proxy routes these):"
echo "  Glances:  http://localhost/glances/"
echo "  Dozzle:   http://localhost/monitoring/"
echo "  HTTPS:    https://${TS_FQDN}   (requires certs in $CERTS_DIR)"