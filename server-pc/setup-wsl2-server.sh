#!/usr/bin/env bash
# Run inside WSL2 Ubuntu on the Windows PC.
# Installs Podman (rootless), creates gitlab-net, starts GitLab CE + MinIO,
# creates the MinIO cache bucket, and configures containers to auto-start on WSL reboot.
set -euo pipefail

GITLAB_VERSION="${GITLAB_VERSION:-latest}"
MINIO_VERSION="${MINIO_VERSION:-latest}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
GITLAB_CACHE_BUCKET="${GITLAB_CACHE_BUCKET:-gitlab-cache}"
GITLAB_CONFIG_DIR="${HOME}/gitlab/config"
GITLAB_LOGS_DIR="${HOME}/gitlab/logs"
MINIO_DATA_DIR="${HOME}/minio-data"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup-server]${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup-server]${NC} $*"; }
error() { echo -e "${RED}[setup-server]${NC} $*" >&2; exit 1; }

CURRENT_USER="$(whoami)"

# Rootless Podman requires subuid/subgid entries for the current user.
if ! grep -q "^${CURRENT_USER}:" /etc/subuid 2>/dev/null; then
  info "Adding subuid entry for ${CURRENT_USER}..."
  echo "${CURRENT_USER}:100000:65536" | sudo tee -a /etc/subuid
fi
if ! grep -q "^${CURRENT_USER}:" /etc/subgid 2>/dev/null; then
  info "Adding subgid entry for ${CURRENT_USER}..."
  echo "${CURRENT_USER}:100000:65536" | sudo tee -a /etc/subgid
fi

if ! command -v podman >/dev/null 2>&1; then
  info "Installing Podman..."
  sudo apt-get update -q
  sudo apt-get install -y -q podman
else
  info "Podman already installed: $(podman --version)"
fi

if ! command -v mc >/dev/null 2>&1; then
  info "Installing MinIO client (mc)..."
  wget -q "https://dl.min.io/client/mc/release/linux-amd64/mc" -O /tmp/mc
  sudo install /tmp/mc /usr/local/bin/mc
  rm /tmp/mc
fi

if ! podman network exists gitlab-net 2>/dev/null; then
  info "Creating Podman network gitlab-net..."
  podman network create gitlab-net
else
  info "Network gitlab-net already exists."
fi

mkdir -p "${GITLAB_CONFIG_DIR}" "${GITLAB_LOGS_DIR}" "${MINIO_DATA_DIR}"

# ── MinIO ─────────────────────────────────────────────────────────────────────
if podman container exists minio 2>/dev/null; then
  info "MinIO container already exists. Starting if stopped..."
  podman start minio 2>/dev/null || true
else
  info "Starting MinIO container..."
  podman run -d \
    --name minio \
    --network gitlab-net \
    -p 9000:9000 \
    -p 9001:9001 \
    -e MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
    -e MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
    -v "${MINIO_DATA_DIR}:/data" \
    "docker.io/minio/minio:${MINIO_VERSION}" \
    server /data --console-address ":9001"
fi

# ── GitLab CE ─────────────────────────────────────────────────────────────────
# Named volume for /var/opt/gitlab keeps UNIX socket files on the WSL2 ext4
# filesystem, avoiding the permission issues that bind mounts to Windows paths cause.
if podman container exists gitlab 2>/dev/null; then
  info "GitLab container already exists. Starting if stopped..."
  podman start gitlab 2>/dev/null || true
else
  info "Creating GitLab data volume..."
  podman volume create gitlab-data 2>/dev/null || true

  info "Starting GitLab CE container (first boot takes 5-10 min)..."
  podman run -d \
    --name gitlab \
    --hostname gitlab.local \
    --network gitlab-net \
    -p 8080:80 \
    -p 2222:22 \
    -v "${GITLAB_CONFIG_DIR}:/etc/gitlab" \
    -v "${GITLAB_LOGS_DIR}:/var/log/gitlab" \
    -v gitlab-data:/var/opt/gitlab \
    "docker.io/gitlab/gitlab-ce:${GITLAB_VERSION}"
fi

# ── Wait for MinIO, then create cache bucket ───────────────────────────────────
info "Waiting for MinIO to be ready..."
MINIO_URL="http://127.0.0.1:9000"
until curl -sf "${MINIO_URL}/minio/health/live" >/dev/null 2>&1; do
  printf "."
  sleep 3
done
echo

info "Configuring MinIO client alias..."
mc alias set local "${MINIO_URL}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --api s3v4 >/dev/null

if mc ls local/"${GITLAB_CACHE_BUCKET}" >/dev/null 2>&1; then
  info "Bucket '${GITLAB_CACHE_BUCKET}' already exists."
else
  info "Creating bucket '${GITLAB_CACHE_BUCKET}'..."
  mc mb local/"${GITLAB_CACHE_BUCKET}"
fi

# ── Auto-start containers on WSL reboot ───────────────────────────────────────
# [boot] command= runs as root on every WSL2 start. We su to the non-root user
# who owns the rootless containers, because rootless Podman stores state under
# that user's XDG directories.
WSL_CONF="/etc/wsl.conf"
BOOT_CMD="su - ${CURRENT_USER} -c 'podman start minio gitlab 2>/dev/null || true'"

if grep -q "\[boot\]" "${WSL_CONF}" 2>/dev/null; then
  warn "/etc/wsl.conf already has a [boot] section. Add this line manually if needed:"
  warn "  command = ${BOOT_CMD}"
else
  info "Writing /etc/wsl.conf boot command..."
  sudo tee -a "${WSL_CONF}" > /dev/null <<WSLCONF

[boot]
command = ${BOOT_CMD}
WSLCONF
fi

info ""
info "========================================"
info "  Server setup complete!"
info "========================================"
info "  MinIO API:     http://127.0.0.1:9000"
info "  MinIO console: http://127.0.0.1:9001"
info "  GitLab:        http://127.0.0.1:8080 (wait 5-10 min for first boot)"
info ""
info "Next steps:"
info "  1. On Windows (Admin PowerShell): .\\server-pc\\expose-ports.ps1"
info "  2. From MacBook: curl http://192.168.1.20:8080/-/health"
info "  3. Get root password:"
info "     podman exec gitlab grep Password: /etc/gitlab/initial_root_password"
info "========================================"
