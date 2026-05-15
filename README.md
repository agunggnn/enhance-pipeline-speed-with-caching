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

---

## Phase 2 — Windows PC as GitLab Runner (Flutter builds)

MacBook becomes too slow for Flutter APK builds. The Windows PC (i5-6500, 16 GB RAM) takes over builds via a GitLab Runner in WSL2, while GitLab CE and MinIO stay on the MacBook.

### Architecture

```
MacBook Pro (Podman, already running):
├── gitlab   → http://<macbook-lan-ip>:8080
└── minio    → http://<macbook-lan-ip>:9000  (cache storage)

Windows PC — WSL2 (Ubuntu 22.04):
└── gitlab-runner (shell executor, tag: wsl2-runner)
    ├── → GitLab  at http://<macbook-lan-ip>:8080
    └── → MinIO   at http://<macbook-lan-ip>:9000
```

> The PC runner is **outside** `gitlab-net` so it uses the MacBook's LAN IP — not container names like `minio:9000`.

### PC Setup (one-time)

**1. Enable WSL2** (PowerShell as Administrator, then reboot):
```powershell
wsl --install -d Ubuntu-22.04
```

**2. Inside WSL2 Ubuntu**, clone this repo and prepare env:
```bash
git clone <repo-url>
cd enhance-pipeline-speed-with-caching
cp .env.example .env
# Edit .env: set MACBOOK_LAN_IP to your MacBook's LAN IP (e.g. 192.168.1.x)
# Find MacBook IP: ipconfig getifaddr en0
nano .env
```

**3. Install dependencies + Flutter SDK:**
```bash
bash runner-pc/setup-wsl2.sh
```
This installs: GitLab Runner, Flutter 3.19.6, Android SDK (platform 34), Java 17.

**4. Register the runner with MacBook's GitLab:**
- Open `http://<macbook-lan-ip>:8080` → Admin → CI/CD → Runners → New instance runner
- Select Linux, tag it `wsl2-runner`, click Create, copy the token
- Add `GITLAB_RUNNER_TOKEN=<token>` to `.env`

```bash
bash runner-pc/register.sh
```

Verify in GitLab: Admin → CI/CD → Runners — `pc-wsl2-flutter-runner` should show **online**.

**5. WSL2 autostart on Windows boot** (optional — Task Scheduler):
- Trigger: At startup
- Action: `wsl -u root service gitlab-runner start`

### Flutter Pipeline

Files are in `pipelines/flutter/`. Create a GitLab project, push those files, and the pipeline runs on the PC runner.

Toggle `CACHE_ENABLED` at pipeline trigger time:
- `true` (default) — warm run, deps restored from MinIO
- `false` — cold run, full download from internet

### Benchmark

```bash
# Set GITLAB_API_TOKEN and GITLAB_PROJECT_ID in .env first
bash scripts/benchmark.sh
```

Triggers a cold pipeline then a warm pipeline and prints the speedup.

**Expected results on i5-6500:**

| Stage | Cold | Warm |
|---|---|---|
| Flutter SDK setup | ~3–4 min | ~30s |
| pub get | ~2 min | ~10s |
| APK build (Gradle) | ~10–15 min | ~10–15 min |
| Tests | ~1 min | ~1 min |
| **Total** | **~15–22 min** | **~12–17 min** |

> Gradle compilation is not cached here. Add `~/.gradle/caches/` as a third cache key to save another 3–5 min on warm runs.
