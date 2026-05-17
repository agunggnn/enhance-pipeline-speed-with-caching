#!/usr/bin/env bash
# Installs tinyproxy on macOS and configures it as an HTTP proxy for Podman
# job containers that need to reach Nexus via the macOS VPN tunnel.
#
# Proxy flow:
#   job container -> HTTP_PROXY=http://<gateway>:8888 -> tinyproxy (macOS) -> VPN -> Nexus
#
# The gateway IP is the macOS-side address of Podman Machine's virtual bridge
# (written to ~/.gitlab-runner-podman.env by setup-macos.sh). Containers in the
# Podman VM reach macOS services via this IP, not via 127.0.0.1.
#
# tinyproxy does NOT use a Bind directive here so it listens on 0.0.0.0. Access
# is restricted to the Podman gateway subnet and localhost via the Allow ACL.
set -euo pipefail

PROXY_PORT="${NEXUS_PROXY_PORT:-8888}"
TINYPROXY_CONF_DIR="${HOME}/.config/tinyproxy"
TINYPROXY_CONF="${TINYPROXY_CONF_DIR}/tinyproxy.conf"
TINYPROXY_LOG="${HOME}/Library/Logs/tinyproxy.log"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/com.gitlab-runner.tinyproxy.plist"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[nexus-proxy]${NC} $*"; }
warn()  { echo -e "${YELLOW}[nexus-proxy]${NC} $*"; }
error() { echo -e "${RED}[nexus-proxy]${NC} $*" >&2; exit 1; }

HELPER_ENV="${HOME}/.gitlab-runner-podman.env"
if [ -f "${HELPER_ENV}" ]; then
  # shellcheck disable=SC1090
  source "${HELPER_ENV}"
else
  error "${HELPER_ENV} not found. Run setup-macos.sh first."
fi

GATEWAY_IP="${PODMAN_GATEWAY_IP:-}"
if [ -z "${GATEWAY_IP}" ]; then
  error "PODMAN_GATEWAY_IP not set. Run setup-macos.sh to detect it."
fi

# Derive the /24 subnet from the gateway IP for the Allow ACL.
GATEWAY_SUBNET="${GATEWAY_IP%.*}.0/24"

if ! command -v tinyproxy >/dev/null 2>&1; then
  info "Installing tinyproxy..."
  brew install tinyproxy
else
  info "tinyproxy already installed: $(tinyproxy -v 2>&1 | head -1)"
fi

mkdir -p "${TINYPROXY_CONF_DIR}"
cat > "${TINYPROXY_CONF}" <<CONF
Port ${PROXY_PORT}

# No Bind directive — tinyproxy listens on 0.0.0.0 so both 127.0.0.1 (macOS
# tests) and the Podman gateway IP (VM containers) can reach it. Access is
# restricted by the Allow ACL below.
Allow 127.0.0.1
Allow ${GATEWAY_SUBNET}

Timeout 600
MaxClients 50
LogFile "${TINYPROXY_LOG}"
LogLevel Info
PidFile /tmp/tinyproxy-gitlab.pid
CONF

info "Config written to ${TINYPROXY_CONF}"

# Stop existing instance before reloading config.
if launchctl list 2>/dev/null | grep -q "com.gitlab-runner.tinyproxy"; then
  info "Stopping existing tinyproxy launchd service..."
  launchctl unload "${LAUNCHD_PLIST}" 2>/dev/null || true
fi

TINYPROXY_BIN="$(command -v tinyproxy)"
cat > "${LAUNCHD_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.gitlab-runner.tinyproxy</string>
  <key>ProgramArguments</key>
  <array>
    <string>${TINYPROXY_BIN}</string>
    <string>-c</string>
    <string>${TINYPROXY_CONF}</string>
    <string>-d</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${TINYPROXY_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${TINYPROXY_LOG}</string>
</dict>
</plist>
PLIST

info "Loading launchd service..."
launchctl load "${LAUNCHD_PLIST}"

sleep 2

if curl -sf --proxy "http://127.0.0.1:${PROXY_PORT}" http://example.com >/dev/null 2>&1; then
  info "Proxy working (localhost -> internet via tinyproxy)."
else
  warn "Proxy verification failed. Check logs: ${TINYPROXY_LOG}"
fi

info ""
info "========================================"
info "  Nexus proxy setup complete!"
info "========================================"
info "  Proxy port:   ${PROXY_PORT}"
info "  Allowed from: 127.0.0.1 and ${GATEWAY_SUBNET}"
info ""
info "  In job containers, Nexus traffic routes via:"
info "    HTTP_PROXY=http://${GATEWAY_IP}:${PROXY_PORT}"
info "    HTTPS_PROXY=http://${GATEWAY_IP}:${PROXY_PORT}"
info ""
info "  Test from inside a container:"
info "    podman run --rm \\"
info "      -e HTTP_PROXY=http://${GATEWAY_IP}:${PROXY_PORT} \\"
info "      alpine wget -qO- http://example.com"
info ""
info "  Logs:   ${TINYPROXY_LOG}"
info "  Manage: launchctl [start|stop|unload] com.gitlab-runner.tinyproxy"
info "========================================"
