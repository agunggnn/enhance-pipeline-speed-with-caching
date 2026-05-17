#!/usr/bin/env bash
# Run on the MacBook Pro.
# Installs Podman + Podman Machine via Homebrew, initialises the VM,
# installs gitlab-runner, and writes ~/.gitlab-runner-podman.env with the
# Podman socket path and gateway IP needed by register.sh and nexus-proxy.sh.
set -euo pipefail

MACHINE_NAME="gitlab-runner-vm"
MACHINE_CPUS="${MACHINE_CPUS:-4}"
MACHINE_MEMORY="${MACHINE_MEMORY:-8192}"   # MB
MACHINE_DISK="${MACHINE_DISK:-60}"         # GB

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup-macos]${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup-macos]${NC} $*"; }
error() { echo -e "${RED}[setup-macos]${NC} $*" >&2; exit 1; }

if ! command -v brew >/dev/null 2>&1; then
  error "Homebrew not found. Install from https://brew.sh then re-run."
fi

if ! command -v podman >/dev/null 2>&1; then
  info "Installing Podman..."
  brew install podman
else
  info "Podman already installed: $(podman --version)"
fi

EXISTING_MACHINE=$(podman machine list --format '{{.Name}}' 2>/dev/null | grep "^${MACHINE_NAME}$" || true)

if [ -z "${EXISTING_MACHINE}" ]; then
  info "Initialising Podman Machine '${MACHINE_NAME}' (${MACHINE_CPUS} CPUs, ${MACHINE_MEMORY}MB RAM, ${MACHINE_DISK}GB disk)..."
  podman machine init \
    --cpus "${MACHINE_CPUS}" \
    --memory "${MACHINE_MEMORY}" \
    --disk-size "${MACHINE_DISK}" \
    "${MACHINE_NAME}"
else
  info "Podman Machine '${MACHINE_NAME}' already exists."
fi

MACHINE_STATE=$(podman machine list --format '{{.Name}} {{.Running}}' 2>/dev/null \
  | grep "^${MACHINE_NAME} " | awk '{print $2}' || echo "false")

if [ "${MACHINE_STATE}" != "true" ]; then
  info "Starting Podman Machine '${MACHINE_NAME}'..."
  podman machine start "${MACHINE_NAME}"
else
  info "Podman Machine '${MACHINE_NAME}' is already running."
fi

# ── Discover socket path ───────────────────────────────────────────────────────
SOCKET_PATH=$(podman machine inspect "${MACHINE_NAME}" \
  --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || true)

if [ -z "${SOCKET_PATH}" ]; then
  error "Could not determine Podman socket path. Check: podman machine inspect ${MACHINE_NAME}"
fi

# ── Discover Podman Machine gateway IP ────────────────────────────────────────
# The gateway is the macOS-side address of gvproxy's virtual bridge. Job
# containers inside the VM reach macOS services (like tinyproxy) via this IP.
# We read it by running a container and checking its default route, which is
# more reliable than parsing machine inspect output across Podman versions.
GATEWAY_IP=$(DOCKER_HOST="unix://${SOCKET_PATH}" \
  podman run --rm alpine sh -c "ip route | awk '/default/{print \$3}'" 2>/dev/null || echo "")

if [ -z "${GATEWAY_IP}" ]; then
  # Fallback for older Podman versions or alternative network modes
  GATEWAY_IP="192.168.127.1"
  warn "Could not auto-detect gateway IP. Using default: ${GATEWAY_IP}"
  warn "Verify with: podman run --rm alpine ip route"
fi

if ! command -v gitlab-runner >/dev/null 2>&1; then
  info "Installing gitlab-runner..."
  brew install gitlab-runner
else
  info "gitlab-runner already installed: $(gitlab-runner --version | head -1)"
fi

# Write helper env so register.sh and nexus-proxy.sh don't need to re-detect.
HELPER_ENV="${HOME}/.gitlab-runner-podman.env"
cat > "${HELPER_ENV}" <<ENV
PODMAN_MACHINE_NAME=${MACHINE_NAME}
PODMAN_SOCKET_PATH=${SOCKET_PATH}
DOCKER_HOST=unix://${SOCKET_PATH}
PODMAN_GATEWAY_IP=${GATEWAY_IP}
ENV
chmod 600 "${HELPER_ENV}"
info "Wrote ${HELPER_ENV}"

info ""
info "========================================"
info "  Podman Machine setup complete!"
info "========================================"
info "  Machine:      ${MACHINE_NAME}"
info "  Socket:       ${SOCKET_PATH}"
info "  DOCKER_HOST:  unix://${SOCKET_PATH}"
info "  Gateway IP:   ${GATEWAY_IP}"
info ""
info "Next steps:"
info "  1. runner-macbook/nexus-proxy.sh   — set up HTTP proxy for Nexus VPN access"
info "  2. runner-macbook/register.sh      — register the GitLab Runner"
info "========================================"
