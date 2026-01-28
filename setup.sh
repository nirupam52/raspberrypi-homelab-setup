#!/usr/bin/env bash
set -euo pipefail

HOMELAB_DIR="$HOME/homelab"
CERTS_DIR="$HOMELAB_DIR/config/certs"
ENV_FILE="$HOMELAB_DIR/.env"

info() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$1"; }

# ── 1. Install Docker if missing ────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    info "Installing Docker via official convenience script"
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    warn "Added $USER to the docker group. You may need to log out and back in."
else
    info "Docker already installed ($(docker --version))"
fi

# ── 2. Install and configure Tailscale ───────────────────────────────────────
if ! command -v tailscale &>/dev/null; then
    info "Installing Tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
fi

if ! tailscale status &>/dev/null; then
    info "Starting Tailscale — follow the login URL to authenticate"
    sudo tailscale up
fi

info "Fetching Tailscale network info"
TS_IP=$(tailscale ip -4)
TS_FQDN=$(tailscale status --json | grep -oP '"DNSName"\s*:\s*"\K[^"]+' | head -1)
TS_FQDN="${TS_FQDN%.}" # strip trailing dot

if [[ -z "$TS_IP" || -z "$TS_FQDN" ]]; then
    warn "Could not determine Tailscale IP or DNS name. Is Tailscale connected?"
    exit 1
fi

info "Tailscale IP: $TS_IP"
info "Tailscale DNS: $TS_FQDN"

# ── 3. Generate .env file ───────────────────────────────────────────────────
info "Writing .env file"
cat > "$ENV_FILE" << EOF
TS_IP=${TS_IP}
TS_FQDN=${TS_FQDN}
EOF

# ── 4. Create certs directory ───────────────────────────────────────────────
mkdir -p "$CERTS_DIR"

if [ -z "$(ls -A "$CERTS_DIR" 2>/dev/null)" ]; then
    warn "Certs directory is empty: $CERTS_DIR"
    echo "  Place your TLS certificate and key for $TS_FQDN here."
    echo "  Expected files: ${TS_FQDN}.crt and ${TS_FQDN}.key"
    echo ""
    echo "  HTTPS will not work until certificates are in place."
    echo "  HTTP on port 80 will still function."
fi

# ── 5. Start services ───────────────────────────────────────────────────────
info "Starting services"
cd "$HOMELAB_DIR"
docker compose up -d

info "Setup complete. Services:"
echo "  Glances:  http://localhost/glances/"
echo "  Dozzle:   http://localhost/monitoring/"
echo "  HTTPS:    https://$TS_FQDN (requires certs)"
