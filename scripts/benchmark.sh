#!/usr/bin/env bash
# Triggers two sequential Flutter pipeline runs (cold then warm) and reports speedup.
# Run from any machine that can reach the MacBook GitLab.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[bench]${NC} $*"; }
warn()  { echo -e "${YELLOW}[bench]${NC} $*"; }
error() { echo -e "${RED}[bench]${NC} $*" >&2; exit 1; }

if [ ! -f "${ROOT_DIR}/.env" ]; then
  error ".env not found. Copy .env.example to .env and fill in MACBOOK_LAN_IP, GITLAB_API_TOKEN, GITLAB_PROJECT_ID."
fi
set -a; source "${ROOT_DIR}/.env"; set +a

: "${MACBOOK_LAN_IP:?}"
: "${GITLAB_API_TOKEN:?GITLAB_API_TOKEN must be set — GitLab UI: User > Preferences > Access Tokens (scope: api)}"
: "${GITLAB_PROJECT_ID:?GITLAB_PROJECT_ID must be set — find in project Settings > General}"

API="http://${MACBOOK_LAN_IP}:8080/api/v4"
H=(-H "PRIVATE-TOKEN: ${GITLAB_API_TOKEN}")

# ── Helpers ───────────────────────────────────────────────────────────────────

trigger_pipeline() {
  local cache_enabled="$1"
  local result
  result=$(curl -sf -X POST \
    "${H[@]}" \
    --form "ref=main" \
    --form "variables[CACHE_ENABLED]=${cache_enabled}" \
    "${API}/projects/${GITLAB_PROJECT_ID}/pipeline")
  echo "${result}" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*'
}

wait_pipeline() {
  local pid="$1"
  local max=1800
  local elapsed=0
  while true; do
    local status
    status=$(curl -sf "${H[@]}" "${API}/projects/${GITLAB_PROJECT_ID}/pipelines/${pid}" \
      | grep -o '"status":"[^"]*"' | head -1 | tr -d '"status:')
    case "${status}" in
      success)   echo; return 0 ;;
      failed|canceled|skipped) echo; warn "Pipeline ${pid} ended: ${status}"; return 1 ;;
      *)
        printf "\r[bench] Pipeline %s — %-12s (%ds)" "${pid}" "${status}" "${elapsed}"
        sleep 20; elapsed=$((elapsed + 20))
        ;;
    esac
    [ "${elapsed}" -lt "${max}" ] || { echo; error "Timed out after ${max}s."; }
  done
}

get_duration() {
  curl -sf "${H[@]}" "${API}/projects/${GITLAB_PROJECT_ID}/pipelines/$1" \
    | grep -o '"duration":[0-9]*' | head -1 | grep -o '[0-9]*'
}

# ── Run benchmark ─────────────────────────────────────────────────────────────

info ""
info "GitLab: http://${MACBOOK_LAN_IP}:8080"
info "Project ID: ${GITLAB_PROJECT_ID}"
info ""

info "Step 1/2 — Cold run (CACHE_ENABLED=false)"
COLD_ID=$(trigger_pipeline "false")
info "Pipeline #${COLD_ID} triggered."
wait_pipeline "${COLD_ID}"
COLD_SEC=$(get_duration "${COLD_ID}")
info "Cold pipeline finished in ${COLD_SEC}s."

info ""
info "Step 2/2 — Warm run (CACHE_ENABLED=true, cache uploaded by cold run)"
WARM_ID=$(trigger_pipeline "true")
info "Pipeline #${WARM_ID} triggered."
wait_pipeline "${WARM_ID}"
WARM_SEC=$(get_duration "${WARM_ID}")
info "Warm pipeline finished in ${WARM_SEC}s."

# ── Results ───────────────────────────────────────────────────────────────────
if [ -n "${COLD_SEC}" ] && [ -n "${WARM_SEC}" ] && [ "${WARM_SEC}" -gt 0 ]; then
  SAVED=$((COLD_SEC - WARM_SEC))
  SPEEDUP=$(echo "scale=2; ${COLD_SEC} / ${WARM_SEC}" | bc)
  PCT=$(echo "scale=1; ${SAVED} * 100 / ${COLD_SEC}" | bc)

  echo ""
  echo "========================================"
  echo "  BENCHMARK RESULTS"
  echo "========================================"
  printf "  Cold (no cache):   %5ds  (~%dm)\n" "${COLD_SEC}" "$((COLD_SEC / 60))"
  printf "  Warm (with cache): %5ds  (~%dm)\n" "${WARM_SEC}" "$((WARM_SEC / 60))"
  printf "  Time saved:        %5ds  (~%dm)\n" "${SAVED}"    "$((SAVED / 60))"
  printf "  Speedup:           %sx\n"           "${SPEEDUP}"
  printf "  Reduction:         %s%%\n"          "${PCT}"
  echo ""
  echo "  Pipelines:"
  echo "  Cold: http://${MACBOOK_LAN_IP}:8080/${GITLAB_PROJECT_ID}/pipelines/${COLD_ID}"
  echo "  Warm: http://${MACBOOK_LAN_IP}:8080/${GITLAB_PROJECT_ID}/pipelines/${WARM_ID}"
  echo "========================================"
fi
