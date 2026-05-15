# enhance-pipeline-speed-with-caching

POC: accelerate GitLab CI pipelines by storing dependency caches in MinIO (local S3). On first run, dependencies are uploaded to MinIO. On subsequent runs, the runner restores from cache — skipping the download entirely.

---

## Architecture

All components run as Podman containers on an isolated network:

```
gitlab-net (Podman bridge network)
├── gitlab        — GitLab CE  (host ports: 8080 HTTP, 2222 SSH)
├── minio         — MinIO S3   (host ports: 9000 API, 9001 console)
└── gitlab-runner — GitLab Runner (shell executor, no exposed ports)
```

Containers resolve each other by name (`http://gitlab`, `minio:9000`).

> **macOS + Podman note:** `/var/opt/gitlab` must be a **Podman named volume**, not a macOS bind mount. macOS uses virtiofs for bind mounts, which cannot host UNIX domain sockets — and PostgreSQL (bundled in GitLab) creates a socket there. Config and logs are fine as bind mounts since they only contain regular files.

---

## Prerequisites

- Podman installed and machine running (rootful recommended)
- ~16 GB RAM available for the Podman machine
- Ports 8080, 2222, 9000, 9001 free on the host

---

## STEP 0 — Podman network

```bash
podman network create gitlab-net
```

---

## STEP 1 — MinIO

```bash
podman run -d \
  --name minio \
  --network gitlab-net \
  -p 9000:9000 \
  -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  -v ~/minio-data:/data \
  docker.io/minio/minio server /data --console-address ":9001"
```

Open `http://localhost:9001` (minioadmin / minioadmin) and create bucket: **`gitlab-cache`**

---

## STEP 2 — GitLab CE

### Create the Podman named volume (required on macOS)

```bash
podman volume create gitlab-data
```

### Run GitLab

```bash
podman run -d \
  --name gitlab \
  --hostname gitlab.local \
  --network gitlab-net \
  -p 8080:80 \
  -p 2222:22 \
  -v ~/gitlab/config:/etc/gitlab \
  -v ~/gitlab/logs:/var/log/gitlab \
  -v gitlab-data:/var/opt/gitlab \
  docker.io/gitlab/gitlab-ce:latest
```

> Key difference from the typical Docker setup: `/var/opt/gitlab` uses `-v gitlab-data:` (named volume), not a macOS bind mount path.

### Wait for first boot (5–10 min)

```bash
podman logs -f gitlab
```

Success: `gitlab Reconfigured!` appears, then nginx access log lines begin streaming.

### Access

URL: `http://localhost:8080`

Get root password:
```bash
cat ~/gitlab/config/initial_root_password
```

---

## STEP 3 — GitLab Runner

### Run

```bash
mkdir -p ~/gitlab-runner

podman run -d \
  --name gitlab-runner \
  --network gitlab-net \
  -v ~/gitlab-runner:/etc/gitlab-runner \
  docker.io/gitlab/gitlab-runner:latest
```

### Register

GitLab 17+ uses an authentication token flow. Create a runner in the UI first:
**Admin → CI/CD → Runners → New instance runner** — then copy the token.

```bash
podman exec -it gitlab-runner gitlab-runner register \
  --non-interactive \
  --url "http://gitlab" \
  --token "<TOKEN_FROM_GITLAB_UI>" \
  --executor "shell" \
  --description "local-mac-runner"
```

Or via API (no UI needed):

```bash
# 1. Get OAuth token
TOKEN=$(curl -s -X POST http://localhost:8080/oauth/token \
  --data-urlencode "grant_type=password" \
  --data-urlencode "username=root" \
  --data-urlencode "password=<ROOT_PASSWORD>" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# 2. Create personal access token
PAT=$(curl -s -X POST "http://localhost:8080/api/v4/users/1/personal_access_tokens" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"admin-pat","scopes":["api"]}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# 3. Create runner, get authentication token
RUNNER_TOKEN=$(curl -s -X POST "http://localhost:8080/api/v4/user/runners" \
  -H "PRIVATE-TOKEN: $PAT" \
  -H "Content-Type: application/json" \
  -d '{"runner_type":"instance_type","description":"local-mac-runner","tag_list":["local","shell"],"run_untagged":true}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# 4. Register
podman exec -it gitlab-runner gitlab-runner register \
  --non-interactive \
  --url "http://gitlab" \
  --token "$RUNNER_TOKEN" \
  --executor "shell" \
  --description "local-mac-runner"
```

---

## STEP 4 — Configure MinIO cache

Edit `~/gitlab-runner/config.toml` — update the `[runners.cache]` block:

```toml
[runners.cache]
  Type = "s3"
  Shared = true
  MaxUploadedArchiveSize = 0
  [runners.cache.s3]
    ServerAddress = "minio:9000"
    AccessKey = "minioadmin"
    SecretKey = "minioadmin"
    BucketName = "gitlab-cache"
    Insecure = true
```

Restart runner:

```bash
podman restart gitlab-runner
```

---

## STEP 5 — Validate with a sample pipeline

Create a project in GitLab and add `.gitlab-ci.yml`:

```yaml
stages:
  - build

cache:
  key: "node-deps-v1"
  paths:
    - node_modules/

build:
  stage: build
  tags:
    - local
  script:
    - mkdir -p node_modules
    - echo "dep-version-1.0.0" > node_modules/package.txt
    - cat node_modules/package.txt
```

**Run #1** — job log shows:
```
Checking cache for node-deps-v1-protected...
Failed to extract cache          ← first run, no cache yet
...
Uploading cache.zip to http://minio:9000/gitlab-cache/...
Created cache                    ← uploaded to MinIO ✓
```

**Run #2** — job log shows:
```
Checking cache for node-deps-v1-protected...
Successfully extracted cache     ← restored from MinIO ✓
```

Verify objects appear in MinIO console: `http://localhost:9001` → bucket `gitlab-cache`.

---

## Common Issues

### GitLab won't start — PostgreSQL socket error

```
PG::ConnectionBad: ...socket "/var/opt/gitlab/postgresql/.s.PGSQL.5432"... No such file or directory
```

Cause: the data volume is a macOS bind mount (virtiofs can't host UNIX sockets).

Fix: use a named volume for `/var/opt/gitlab`:
```bash
podman stop gitlab && podman rm gitlab
podman volume create gitlab-data
# re-run with -v gitlab-data:/var/opt/gitlab
```

### Runner can't reach GitLab

Use `http://gitlab` (container DNS), never `localhost`.

### Docker socket not found

On macOS rootful Podman, use the Podman socket:
```bash
-v $XDG_RUNTIME_DIR/podman/podman.sock:/var/run/docker.sock
```
Or use the `shell` executor to avoid the socket requirement entirely.
