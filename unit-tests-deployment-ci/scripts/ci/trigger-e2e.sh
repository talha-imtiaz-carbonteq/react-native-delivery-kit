#!/usr/bin/env bash

# ==============================================================================
# trigger-e2e.sh
# Fetches the latest finished Expo EAS builds (Android + iOS) and triggers
# GitLab E2E child pipelines for each platform.
# ==============================================================================

set -euo pipefail

# ── Colour codes ───────────────────────────────────────────────────────────────
RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'
BLUE='\e[34m'; MAGENTA='\e[35m'; CYAN='\e[36m'; RESET='\e[0m'

# ── Logging helpers ────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${RESET}    $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${RESET} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET}   $*" >&2; }
log_debug()   { echo -e "${MAGENTA}[DEBUG]${RESET}   $*"; }
log_section() { echo -e "\n${CYAN}══════════════════════════════════════════${RESET}"; \
                echo -e "${CYAN}  $*${RESET}"; \
                echo -e "${CYAN}══════════════════════════════════════════${RESET}"; }

# ── Temp file cleanup ──────────────────────────────────────────────────────────
EAS_STDERR_LOG="/tmp/eas_error_$$.log"
CURL_RESPONSE_LOG="/tmp/curl_out_$$.log"
cleanup() {
  rm -f "$EAS_STDERR_LOG" "$CURL_RESPONSE_LOG"
}
trap cleanup EXIT

# ── Track per-platform results for final summary ───────────────────────────────
declare -A PLATFORM_STATUS   # "success" | "failed" | "skipped"

# ==============================================================================
log_section "🚀 Fetching Latest Expo Builds & Triggering E2E"
# ==============================================================================

# ── 1. Resolve paths ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log_info "Script dir  : $SCRIPT_DIR"
log_info "Project root: $PROJECT_ROOT"
cd "$PROJECT_ROOT"

# ── 2. Validate required environment variables ─────────────────────────────────
log_section "🔐 Validating Environment"

# Sanitise ALL variables first — GitLab CI can inject trailing newlines into
# variable values, which causes silent failures in tools like eas-cli that
# perform exact-match UUID validation. Strip all whitespace unconditionally.
EXPO_TOKEN="$(echo -n "${EXPO_TOKEN:-}"         | tr -d '[:space:]')"
EXPO_PROJECT_ID="$(echo -n "${EXPO_PROJECT_ID:-}" | tr -d '[:space:]')"
E2E_PIPELINE_TOKEN="$(echo -n "${E2E_PIPELINE_TOKEN:-}" | tr -d '[:space:]')"
E2E_PROJECT_ID="$(echo -n "${E2E_PROJECT_ID:-}" | tr -d '[:space:]')"

export EXPO_TOKEN
export EXPO_PROJECT_ID

MISSING_VARS=()

# EXPO_TOKEN
if [[ -z "${EXPO_TOKEN}" ]]; then
  MISSING_VARS+=("EXPO_TOKEN")
else
  log_success "EXPO_TOKEN        — set (length: ${#EXPO_TOKEN})"
fi

# EXPO_PROJECT_ID
if [[ -z "${EXPO_PROJECT_ID}" ]]; then
  log_warn "EXPO_PROJECT_ID is not set — attempting auto-detection via EAS..."
  if EXPO_PROJECT_ID=$(EXPO_TOKEN="${EXPO_TOKEN}" npx eas project:info --json 2>/dev/null \
      | jq -r '.id // empty'); then
    EXPO_PROJECT_ID="$(echo -n "$EXPO_PROJECT_ID" | tr -d '[:space:]')"
    if [[ -n "$EXPO_PROJECT_ID" ]]; then
      log_success "EXPO_PROJECT_ID   — auto-detected: $EXPO_PROJECT_ID"
    else
      MISSING_VARS+=("EXPO_PROJECT_ID")
    fi
  else
    MISSING_VARS+=("EXPO_PROJECT_ID")
  fi
else
  log_success "EXPO_PROJECT_ID   — set: $EXPO_PROJECT_ID"
  log_debug   "EXPO_PROJECT_ID   — char count: ${#EXPO_PROJECT_ID} (expect 36)"
fi

# E2E_PIPELINE_TOKEN
if [[ -z "${E2E_PIPELINE_TOKEN}" ]]; then
  MISSING_VARS+=("E2E_PIPELINE_TOKEN")
else
  log_success "E2E_PIPELINE_TOKEN— set (length: ${#E2E_PIPELINE_TOKEN})"
fi

# E2E_PROJECT_ID
if [[ -z "${E2E_PROJECT_ID}" ]]; then
  MISSING_VARS+=("E2E_PROJECT_ID")
else
  log_success "E2E_PROJECT_ID    — set: $E2E_PROJECT_ID"
fi

# Fail fast if anything critical is missing
if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
  log_error "The following required variables are missing or empty:"
  for v in "${MISSING_VARS[@]}"; do
    log_error "  ✖  $v"
  done
  log_error "Set them as GitLab CI/CD variables (masked + protected) and retry."
  exit 1
fi

# ── 3. Runtime dependency checks ───────────────────────────────────────────────
log_section "🛠  Checking Runtime Dependencies"

check_cmd() {
  local cmd=$1
  if command -v "$cmd" &>/dev/null; then
    log_success "$cmd — found at $(command -v "$cmd")"
  else
    log_error "$cmd — NOT FOUND. Install it before running this script."
    exit 1
  fi
}
check_cmd npx
check_cmd jq
check_cmd curl

# ── 4. Environment snapshot (safe — no secret values printed) ──────────────────
log_section "📋 Environment Snapshot"
log_debug "PWD              : $(pwd)"
log_debug "EXPO_PROJECT_ID  : $EXPO_PROJECT_ID"
log_debug "EXPO_TOKEN set   : ${EXPO_TOKEN:+yes}"
log_debug "EXPO_TOKEN length: ${#EXPO_TOKEN}"
log_debug "E2E_PROJECT_ID   : $E2E_PROJECT_ID"
log_debug "Node version     : $(node --version 2>/dev/null || echo 'not found')"
log_debug "npm version      : $(npm --version 2>/dev/null || echo 'not found')"
log_debug "npx version      : $(npx --version 2>/dev/null || echo 'not found')"

# ── 5. Per-platform processing ─────────────────────────────────────────────────
process_platform() {
  local platform=$1
  log_section "🔍 Processing platform: ${platform^^}"

  # ── 5a. Fetch latest build ─────────────────────────────────────────────────
  log_info "Running: eas build:list --project-id $EXPO_PROJECT_ID --platform $platform --status finished --limit 1 --json --non-interactive"

  # ── 5a. Fetch latest build via Expo GraphQL API ────────────────────────────
  # We bypass eas-cli entirely. The CLI requires an interactive project
  # directory (eas.json present + npx context) which is unreliable in CI
  # child pipelines. The GraphQL API accepts EXPO_TOKEN directly and has
  # no such requirement.
  local platform_upper
  platform_upper="${platform^^}"   # android → ANDROID, ios → IOS

  local graphql_query
  graphql_query=$(cat <<GQL
{
  "query": "query GetLatestBuild(\$appId: String!, \$platform: AppPlatform!, \$status: BuildStatus) { app { byId(appId: \$appId) { builds(platform: \$platform, status: \$status, offset: 0, limit: 1) { id status platform createdAt artifacts { buildUrl } } } } }",
  "variables": {
    "appId": "${EXPO_PROJECT_ID}",
    "platform": "${platform_upper}",
    "status": "FINISHED"
  }
}
GQL
)

  log_debug "Querying Expo GraphQL API for latest $platform build..."

  local api_http_code api_body api_curl_exit=0
  api_http_code=$(
    curl -s \
      --max-time 30 \
      --retry 3 \
      --retry-delay 5 \
      -w "%{http_code}" \
      -o "$EAS_STDERR_LOG" \
      -X POST \
      -H "Authorization: Bearer ${EXPO_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$graphql_query" \
      "https://api.expo.dev/graphql"
  ) || api_curl_exit=$?

  api_body=$(cat "$EAS_STDERR_LOG")

  log_debug "Expo API HTTP status: $api_http_code"
  log_debug "Expo API raw response: $api_body"

  if [[ $api_curl_exit -ne 0 ]]; then
    log_error "curl failed reaching Expo API (exit code $api_curl_exit). Check network connectivity."
    PLATFORM_STATUS[$platform]="failed"
    return 1
  fi

  if [[ "$api_http_code" != "200" ]]; then
    log_error "Expo API returned HTTP $api_http_code — expected 200."
    log_error "Response body: $api_body"
    if [[ "$api_http_code" == "401" ]]; then
      log_error "EXPO_TOKEN is invalid or expired. Generate a new one at https://expo.dev/accounts/[account]/settings/access-tokens"
    fi
    PLATFORM_STATUS[$platform]="failed"
    return 1
  fi

  # Check for GraphQL-level errors (HTTP 200 but errors array populated)
  local gql_errors
  gql_errors=$(echo "$api_body" | jq -r '.errors // empty')
  if [[ -n "$gql_errors" ]]; then
    log_error "Expo GraphQL returned errors for $platform:"
    echo "$api_body" | jq '.errors[] | "  \(.message)"' -r | while IFS= read -r line; do
      log_error "$line"
    done
    log_error "Verify EXPO_PROJECT_ID ($EXPO_PROJECT_ID) is correct and belongs to this token's account."
    PLATFORM_STATUS[$platform]="failed"
    return 1
  fi

  # ── 5b. Parse GraphQL response ─────────────────────────────────────────────
  local build_json
  build_json=$(echo "$api_body" | jq '.data.app.byId.builds')

  local build_count
  build_count=$(echo "$build_json" | jq '. | length')
  log_debug "Builds returned by API: $build_count"

  if [[ "$build_count" -eq 0 ]]; then
    log_warn "No finished builds found for $platform in project $EXPO_PROJECT_ID."
    log_warn "Trigger a build first: eas build --platform $platform"
    PLATFORM_STATUS[$platform]="skipped"
    return 0
  fi

  # ── 5c. Extract build metadata ─────────────────────────────────────────────
  local build_id build_status build_url created_at
  build_id=$(echo    "$build_json" | jq -r '.[0].id')
  build_status=$(echo "$build_json" | jq -r '.[0].status')
  build_url=$(echo   "$build_json" | jq -r '.[0].artifacts.buildUrl // empty')
  created_at=$(echo  "$build_json" | jq -r '.[0].createdAt // "unknown"')

  log_info "Build ID   : $build_id"
  log_info "Status     : $build_status"
  log_info "Created at : $created_at"
  log_info "Build URL  : ${build_url:-<not available>}"

  if [[ -z "$build_url" ]]; then
    log_error "Build $build_id has no downloadable artifact URL."
    log_error "The artifact may have expired (EAS artifacts expire after 30 days by default)."
    log_error "Re-trigger an EAS build to produce a fresh artifact."
    PLATFORM_STATUS[$platform]="failed"
    return 1
  fi

  log_success "✅ Valid $platform build found: $build_id"

  # ── 5d. Trigger GitLab E2E pipeline ───────────────────────────────────────
  log_section "📡 Triggering GitLab E2E — ${platform^^}"
  log_info "Target project ID: $E2E_PROJECT_ID"
  log_info "Target ref       : main"
  log_info "EXPO_BUILD_URL   : $build_url"
  log_info "EXPO_PLATFORM    : $platform"

  local http_code curl_exit=0
  http_code=$(
    curl -s \
      --max-time 30 \
      --retry 3 \
      --retry-delay 5 \
      --retry-connrefused \
      -w "%{http_code}" \
      -o "$CURL_RESPONSE_LOG" \
      -X POST \
      -F "token=${E2E_PIPELINE_TOKEN}" \
      -F "ref=ci-test" \
      -F "variables[EXPO_BUILD_URL]=$build_url" \
      -F "variables[EXPO_PLATFORM]=$platform" \
      "https://gitlab.com/api/v4/projects/${E2E_PROJECT_ID}/trigger/pipeline"
  ) || curl_exit=$?

  if [[ $curl_exit -ne 0 ]]; then
    log_error "curl failed with exit code $curl_exit (network error or timeout)."
    log_error "Check connectivity from this runner to gitlab.com."
    PLATFORM_STATUS[$platform]="failed"
    return 1
  fi

  local curl_body
  curl_body=$(cat "$CURL_RESPONSE_LOG")
  log_debug "GitLab API HTTP status : $http_code"
  log_debug "GitLab API response body:"
  # Pretty-print if JSON, otherwise raw
  if echo "$curl_body" | jq empty 2>/dev/null; then
    log_debug "$(echo "$curl_body" | jq .)"
  else
    log_debug "$curl_body"
  fi

  case "$http_code" in
    201)
      local pipeline_id pipeline_url
      pipeline_id=$(echo  "$curl_body" | jq -r '.id   // "unknown"')
      pipeline_url=$(echo "$curl_body" | jq -r '.web_url // "unknown"')
      log_success "✅ E2E pipeline triggered for $platform"
      log_success "   Pipeline ID : $pipeline_id"
      log_success "   Pipeline URL: $pipeline_url"
      PLATFORM_STATUS[$platform]="success"
      ;;
    401)
      log_error "HTTP 401 — Unauthorized. E2E_PIPELINE_TOKEN is invalid or revoked."
      PLATFORM_STATUS[$platform]="failed"
      return 1
      ;;
    403)
      log_error "HTTP 403 — Forbidden. Token lacks permission on project $E2E_PROJECT_ID."
      PLATFORM_STATUS[$platform]="failed"
      return 1
      ;;
    404)
      log_error "HTTP 404 — Project $E2E_PROJECT_ID not found, or the trigger ref 'main' does not exist."
      PLATFORM_STATUS[$platform]="failed"
      return 1
      ;;
    422)
      log_error "HTTP 422 — Unprocessable. The pipeline could not be created (branch rules, protected vars, etc.)."
      log_error "Full response: $curl_body"
      PLATFORM_STATUS[$platform]="failed"
      return 1
      ;;
    *)
      log_error "HTTP $http_code — Unexpected response from GitLab API."
      log_error "Full response: $curl_body"
      PLATFORM_STATUS[$platform]="failed"
      return 1
      ;;
  esac
}

# ── 6. Run both platforms (never abort the whole script on one failure) ─────────
process_platform "android" || true
process_platform "ios"     || true

# ── 7. Final summary ───────────────────────────────────────────────────────────
log_section "📊 Summary"

OVERALL_SUCCESS=true
for platform in android ios; do
  status="${PLATFORM_STATUS[$platform]:-unknown}"
  case "$status" in
    success) log_success "  ${platform^^}  →  ✅ triggered" ;;
    skipped) log_warn    "  ${platform^^}  →  ⚠️  skipped (no finished builds found)" ;;
    failed)  log_error   "  ${platform^^}  →  ❌ failed"; OVERALL_SUCCESS=false ;;
    *)       log_warn    "  ${platform^^}  →  ❓ unknown" ;;
  esac
done

echo ""
if $OVERALL_SUCCESS; then
  log_success "All platforms processed successfully. 🎉"
  exit 0
else
  log_error "One or more platforms failed. Review the errors above."
  exit 1
fi