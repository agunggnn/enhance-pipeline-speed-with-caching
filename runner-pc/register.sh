#!/usr/bin/env bash
# Generates config.toml from template (using .env values) and registers the runner.
# Run inside WSL2 Ubuntu after setup-wsl2.sh completes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[register]${NC} $*"; }
warn()  { echo -e "${YELLOW}[register]${NC} $*"; }
error() { echo -e "${RED}[register]${NC} $*" >&2; exit 1; }

# ── Load .env ─────────────────────────────────────────────────────────────────
if [ ! -f "${ROOT_DIR}/.env" ]; then
  error ".env not found. Copy .env.example to .env and fill in your values."
fi
set -a
source "${ROOT_DIR}/.env"
set +a

: "${MACBOOK_LAN_IP:?MACBOOK_LAN_IP must be set in .env (MacBook's LAN IP)}"
: "${GITLAB_RUNNER_TOKEN:?GITLAB_RUNNER_TOKEN must be set in .env — get it from GitLab UI: Admin > CI/CD > Runners > New instance runner}"
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER must be set in .env}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD must be set in .env}"
: "${GITLAB_CACHE_BUCKET:=gitlab-cache}"

# ── Verify GitLab is reachable ────────────────────────────────────────────────
GITLAB_URL="http://${MACBOOK_LAN_IP}:8080"
info "Checking GitLab at ${GITLAB_URL}..."
if ! curl -sf "${GITLAB_URL}/-/health" >/dev/null 2>&1; then
  error "Cannot reach GitLab at ${GITLAB_URL}. Make sure GitLab is running on the MacBook and the MacBook is on the same network."
fi
info "GitLab is reachable."

# ── Verify MinIO is reachable ─────────────────────────────────────────────────
MINIO_URL="http://${MACBOOK_LAN_IP}:9000"
info "Checking MinIO at ${MINIO_URL}..."
if ! curl -sf "${MINIO_URL}/minio/health/live" >/dev/null 2>&1; then
  error "Cannot reach MinIO at ${MINIO_URL}. Make sure MinIO is running on the MacBook."
fi
info "MinIO is reachable."

# ── Generate config.toml from template ────────────────────────────────────────
TEMPLATE="${SCRIPT_DIR}/config.toml.template"
CONFIG_OUTPUT="/etc/gitlab-runner/config.toml"

info "Generating config.toml from template..."
if ! command -v envsubst >/dev/null 2>&1; then
  error "envsubst not found. Run: sudo apt install gettext-base"
fi

envsubst < "${TEMPLATE}" | sudo tee "${CONFIG_OUTPUT}" > /dev/null
info "Config written to ${CONFIG_OUTPUT}"

# ── Restart and verify runner ──────────────────────────────────────────────────
info "Restarting GitLab Runner service..."
if systemctl is-active --quiet gitlab-runner 2>/dev/null; then
  sudo systemctl restart gitlab-runner
else
  sudo gitlab-runner start 2>/dev/null || sudo service gitlab-runner restart 2>/dev/null || true
fi

sleep 3

info "Verifying runner registration..."
sudo gitlab-runner verify --delete 2>/dev/null || true

info ""
info "========================================"
info "  Runner registered successfully!"
info "========================================"
info "  GitLab:  ${GITLAB_URL}"
info "  MinIO:   ${MINIO_URL}"
info "  Tag:     wsl2-runner (see .gitlab-ci.yml)"
info ""
info "Verify in GitLab UI: Admin > CI/CD > Runners"
info "The runner 'pc-wsl2-flutter-runner' should appear online."
info "========================================"
