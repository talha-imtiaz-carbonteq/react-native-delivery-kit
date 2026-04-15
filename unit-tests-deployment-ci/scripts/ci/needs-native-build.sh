#!/usr/bin/env bash
set -euo pipefail

# --- Logging Helpers ---
log_info() { echo -e "\e[34m[INFO]\e[0m $*"; }
log_match() { echo -e "\e[32m[MATCH]\e[0m $*"; }
log_warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

OUTPUT_ENV_FILE="${SCRIPT_DIR}/build-or-ota.env"

log_info "Starting build decision logic..."

# 1. Determine Base Reference
# Priority 1: MR Diff Base (Most accurate for MRs)
# Priority 2: CI_COMMIT_BEFORE_SHA (The state of the branch BEFORE this push/merge)
# Priority 3: Fallback to HEAD~1 (Previous commit)
if [[ -n "${CI_MERGE_REQUEST_DIFF_BASE_SHA:-}" ]]; then
    BASE_REF="${CI_MERGE_REQUEST_DIFF_BASE_SHA}"
    log_info "Context: Merge Request. Using Diff Base: ${BASE_REF}"
elif [[ -n "${CI_COMMIT_BEFORE_SHA:-}" && "${CI_COMMIT_BEFORE_SHA}" != "0000000000000000000000000000000000000000" ]]; then
    BASE_REF="${CI_COMMIT_BEFORE_SHA}"
    log_info "Context: Push/Merge. Comparing against previous commit: ${BASE_REF}"
else
    BASE_REF="HEAD~1"
    log_warn "Context: Unknown. Falling back to HEAD~1"
fi

# 2. Git Fetching
# We must ensure we have the BASE_REF in our local history to diff against it
log_info "Fetching history to ensure BASE_REF (${BASE_REF}) is available..."
git fetch --no-tags --prune --depth=50 origin "${CI_COMMIT_BRANCH:-main}" >/dev/null 2>&1 || true

# 3. Analyze Changes
# Use a double-dot diff (A..B) to see exactly what changed in this push/merge
CHANGED_FILES="$(git diff --name-only "${BASE_REF}".."${CI_COMMIT_SHA:-HEAD}" || true)"
needs_native_build="false"
trigger_reason="No native changes detected (OTA candidate)"

if [[ -z "${CHANGED_FILES}" ]]; then
  # If it's a web trigger or manual run, we might want a native build. 
  # Otherwise, if it's a push and truly nothing changed, it's an OTA.
  if [[ "$CI_PIPELINE_SOURCE" == "web" ]]; then
      log_info "Manual/Web trigger with no changes detected."
      needs_native_build="true"
      trigger_reason="Manual trigger - defaulting to native build."
  else
      log_info "No files changed in this push. Defaulting to OTA."
      needs_native_build="false"
      trigger_reason="No changes detected in push."
  fi
else
  log_info "Analyzing $(echo "${CHANGED_FILES}" | wc -l | xargs) changed files..."
  
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    
    case "${file}" in
      Propwire/ios/*|Propwire/android/*)
        needs_native_build="true"
        trigger_reason="Native directory change: ${file}"
        log_match "${trigger_reason}"
        break
        ;;
      Propwire/app.config.ts|Propwire/app.config.js|Propwire/eas.json|Propwire/package.json|Propwire/pnpm-lock.yaml)
        needs_native_build="true"
        trigger_reason="Core config/dependency change: ${file}"
        log_match "${trigger_reason}"
        break
        ;;
    esac
  done <<< "${CHANGED_FILES}"
fi

# 4. Final Output
log_info "--- FINAL DECISION ---"
log_info "NEEDS_NATIVE_BUILD: ${needs_native_build}"
log_info "REASON: ${trigger_reason}"

cat > "${OUTPUT_ENV_FILE}" <<EOF
NEEDS_NATIVE_BUILD=${needs_native_build}
EOF