The POC is fully validated. Here's the complete summary:

  ---
  All Done — Full Stack Running

  Containers:

  ┌───────────────┬────────────────────────────────────┐
  │   Container   │               Status               │
  ├───────────────┼────────────────────────────────────┤
  │ minio         │ Up 20+ hours, port 9000/9001       │
  ├───────────────┼────────────────────────────────────┤
  │ gitlab        │ Up ~15 min, healthy, port 8080     │
  ├───────────────┼────────────────────────────────────┤
  │ gitlab-runner │ Up, registered with shell executor │
  └───────────────┴────────────────────────────────────┘

  Root cause fixed: macOS + Podman uses virtiofs for bind mounts, which can't host UNIX sockets. Switching
  /var/opt/gitlab to a Podman named volume (gitlab-data) puts the PostgreSQL socket on the VM's native filesystem
   where it works fine.

  Cache proof (from job traces):
  - Pipeline #1 — "Failed to extract cache" → ran script → "Uploading cache.zip to 
  http://minio:9000/gitlab-cache/..." → "Created cache" ✅ 
  - Pipeline #2 — "Successfully extracted cache" → ran script (deps already there) → cache refreshed ✅

  Access:
  - GitLab UI: http://localhost:8080 (root / cLDirtIa+7/XOONZSrcyzCuUMJ+m4sNmAGvD7vDIqEY=)
  - MinIO console: http://localhost:9001 (minioadmin / minioadmin)
  - Test project: http://localhost:8080/root/cache-test