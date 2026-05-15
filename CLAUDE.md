# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

This is an infrastructure setup project for accelerating GitLab CI pipelines using S3-compatible object caching. The goal is to eliminate redundant dependency downloads (Java, Node.js, React, Flutter) by storing them in MinIO — a local S3-compatible backend — and having GitLab Runner fetch from that cache on subsequent runs.

## Architecture

All components run as Podman containers on the same isolated network (`gitlab-net`):

```
gitlab-net (Podman network)
├── gitlab        — GitLab CE (port 8080 HTTP, 2222 SSH)
├── minio         — MinIO object storage (port 9000 API, 9001 console)
└── gitlab-runner — GitLab Runner (connects to gitlab via container DNS)
```

Runner-to-MinIO cache flow: the runner is configured in `~/gitlab-runner/config.toml` with an S3 cache block pointing at `minio:9000`. Within the network, containers resolve each other by name, so `http://gitlab` and `minio:9000` are the correct addresses (not `localhost`).

## Key Configuration File

`~/gitlab-runner/config.toml` — controls executor type and S3 cache settings:

```toml
[runners.cache]
  Type = "s3"
  Shared = true

  [runners.cache.s3]
    ServerAddress = "minio:9000"
    AccessKey = "minioadmin"
    SecretKey = "minioadmin"
    BucketName = "gitlab-cache"
    Insecure = true
```

After editing this file, restart the runner:

```bash
podman restart gitlab-runner
```

## Operational Commands

### Start / inspect containers

```bash
podman logs -f gitlab              # watch GitLab boot (takes 3–5 min first run)
podman exec -it gitlab-runner sh   # shell into runner to test connectivity
```

### Validate network connectivity (from inside runner)

```bash
ping gitlab
ping minio
```

Both must resolve. If not, the runner is not on `gitlab-net`.

### Retrieve GitLab initial root password

```bash
podman exec -it gitlab grep 'Password:' /etc/gitlab/initial_root_password
```

### Register a new runner

```bash
podman exec -it gitlab-runner gitlab-runner register
# URL:   http://gitlab
# Token: from GitLab UI → Settings → CI/CD → Runners
# Executor: docker (or shell if Docker socket is unavailable)
# Default image: alpine:latest
```

## Podman vs Docker Gotchas

- The Docker socket path (`/var/run/docker.sock`) may not exist under rootless Podman — use `$XDG_RUNTIME_DIR/podman/podman.sock` instead.
- Always use container DNS names (`http://gitlab`, `minio:9000`) inside the network, never `localhost`.
- GitLab CE is heavy; first boot allocates significant RAM and takes several minutes.

## Phase 2: PC Runner for Flutter Builds

The Windows PC (i5-6500, 16 GB RAM) runs a GitLab Runner inside WSL2 to handle heavy Flutter builds, while GitLab CE and MinIO stay on the MacBook.

### File Layout (Phase 2)

```
runner-pc/
  setup-wsl2.sh          — installs GitLab Runner, Flutter SDK, Android SDK, Java 17
  config.toml.template   — runner config; uses MacBook LAN IP (not container DNS)
  register.sh            — envsubst template → /etc/gitlab-runner/config.toml, restarts service
pipelines/
  flutter/
    .gitlab-ci.yml       — benchmark pipeline; tag: wsl2-runner; CACHE_ENABLED variable
    pubspec.yaml         — minimal Flutter app (http + provider deps for realistic cache size)
    lib/main.dart
scripts/
  benchmark.sh           — triggers cold + warm pipelines via GitLab API; prints speedup
.env.example             — template for MACBOOK_LAN_IP, MinIO creds, runner token, API token
.gitignore               — excludes .env
```

### Critical: PC Runner Uses LAN IP, Not Container DNS

The PC runner is outside `gitlab-net`. In `config.toml.template`:
```toml
url = "http://${MACBOOK_LAN_IP}:8080"          # NOT http://gitlab
[runners.cache.s3]
  ServerAddress = "${MACBOOK_LAN_IP}:9000"     # NOT minio:9000
```

### Environment Variables Required in .env

| Variable | Purpose |
|---|---|
| `MACBOOK_LAN_IP` | MacBook's LAN IP — find with `ipconfig getifaddr en0` |
| `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` | MinIO credentials |
| `GITLAB_CACHE_BUCKET` | defaults to `gitlab-cache` |
| `GITLAB_RUNNER_TOKEN` | from GitLab Admin → CI/CD → Runners |
| `GITLAB_API_TOKEN` | for benchmark.sh (scope: api) |
| `GITLAB_PROJECT_ID` | for benchmark.sh (project Settings → General) |

### Pipeline Cache Keys

| Key | Paths | Policy in setup | Policy in build/test |
|---|---|---|---|
| `flutter-sdk-<version>` | `/opt/flutter/` | pull-push | pull |
| `flutter-pub-<pubspec.lock hash>` | `.pub-cache/` | pull-push | pull |

Only `setup` jobs write to cache. `build` and `test` jobs only read, preventing concurrent write conflicts.
