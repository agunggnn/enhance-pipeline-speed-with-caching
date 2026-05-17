#!/usr/bin/env bash
# Generates config.toml from template and registers the macOS Podman runner.
# Run after setup-macos.sh and nexus-proxy.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[register]${NC} $*"; }
warn()  { echo -e "${YELLOW}[register]${NC} $*"; }
error() { echo -e "${RED}[register]${NC} $*" >&2; exit 1; }

if [ ! -f "${ROOT_DIR}/.env" ]; then
  error ".env not found. Copy .env.example to .env and fill in your values."
fi
set -a
source "${ROOT_DIR}/.env"
set +a

: "${PC_LAN_IP:?PC_LAN_IP must be set in .env (Windows PC LAN IP, e.g. 192.168.1.20)}"
: "${GITLAB_RUNNER_TOKEN:?GITLAB_RUNNER_TOKEN must be set — GitLab: Admin > CI/CD > Runners > New instance runner}"
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER must be set in .env}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD must be set in .env}"
GITLAB_CACHE_BUCKET="${GITLAB_CACHE_BUCKET:-gitlab-cache}"

HELPER_ENV="${HOME}/.gitlab-runner-podman.env"
if [ -f "${HELPER_ENV}" ]; then
  # shellcheck disable=SC1090
  source "${HELPER_ENV}"
else
  error "${HELPER_ENV} not found. Run setup-macos.sh first (or set PODMAN_SOCKET_PATH manually in .env)."
fi

: "${PODMAN_SOCKET_PATH:?PODMAN_SOCKET_PATH missing. Run setup-macos.sh or set it manually in .env.}"

# ── Health checks ──────────────────────────────────────────────────────────────
GITLAB_URL="http://${PC_LAN_IP}:8080"
info "Checking GitLab at ${GITLAB_URL}..."
if ! curl -sf "${GITLAB_URL}/-/health" >/dev/null 2>&1; then
  error "Cannot reach GitLab at ${GITLAB_URL}. Check expose-ports.ps1 ran and WSL2 containers are up."
fi
info "GitLab reachable."

MINIO_URL="http://${PC_LAN_IP}:9000"
info "Checking MinIO at ${MINIO_URL}..."
if ! curl -sf "${MINIO_URL}/minio/health/live" >/dev/null 2>&1; then
  error "Cannot reach MinIO at ${MINIO_URL}."
fi
info "MinIO reachable."

if [ ! -S "${PODMAN_SOCKET_PATH}" ]; then
  error "Podman socket not found at ${PODMAN_SOCKET_PATH}. Is Podman Machine running? Run: podman machine start"
fi
info "Podman socket verified."

# ── Generate config.toml ───────────────────────────────────────────────────────
if ! command -v envsubst >/dev/null 2>&1; then
  error "envsubst not found. Run: brew install gettext && brew link gettext --force"
fi

# Homebrew gitlab-runner config location differs by architecture.
if [ -d "/opt/homebrew/etc/gitlab-runner" ]; then
  CONFIG_DIR="/opt/homebrew/etc/gitlab-runner"
elif [ -d "/usr/local/etc/gitlab-runner" ]; then
  CONFIG_DIR="/usr/local/etc/gitlab-runner"
else
  CONFIG_DIR="${HOME}/.gitlab-runner"
  mkdir -p "${CONFIG_DIR}"
  warn "Using fallback config dir: ${CONFIG_DIR}"
fi

CONFIG_OUTPUT="${CONFIG_DIR}/config.toml"
TEMPLATE="${SCRIPT_DIR}/config.toml.template"

info "Generating config.toml -> ${CONFIG_OUTPUT}..."
export PC_LAN_IP GITLAB_RUNNER_TOKEN MINIO_ROOT_USER MINIO_ROOT_PASSWORD \
       GITLAB_CACHE_BUCKET PODMAN_SOCKET_PATH

envsubst < "${TEMPLATE}" > "${CONFIG_OUTPUT}"
chmod 600 "${CONFIG_OUTPUT}"
info "Config written (permissions: 600)."

# ── Restart and verify ────────────────────────────────────────────────────────
info "Restarting gitlab-runner service..."
if brew services list | grep -q "^gitlab-runner"; then
  brew services restart gitlab-runner
else
  brew services start gitlab-runner
fi

sleep 5

info "Verifying runner..."
gitlab-runner verify --delete 2>/dev/null || true

info ""
info "========================================"
info "  Runner registered!"
info "========================================"
info "  GitLab:        ${GITLAB_URL}"
info "  MinIO:         ${MINIO_URL}"
info "  Podman socket: ${PODMAN_SOCKET_PATH}"
info "  Runner tag:    macos-podman-runner"
info ""
info "Verify in GitLab: Admin > CI/CD > Runners"
info "========================================"
