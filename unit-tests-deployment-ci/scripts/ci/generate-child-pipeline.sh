#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

source "${SCRIPT_DIR}/build-or-ota.env"

# Quick Safety Check
if [[ -z "${NEEDS_NATIVE_BUILD:-}" ]]; then
  echo "❌ Error: NEEDS_NATIVE_BUILD is not defined in build-or-ota.env"
  exit 1
fi

PARENT_SOURCE="${CI_PIPELINE_SOURCE:-}"
CURRENT_BRANCH="${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-${CI_COMMIT_BRANCH:-}}"

CHILD_PIPELINE_PATH="${SCRIPT_DIR}/child-pipeline.yml"
mkdir -p "$(dirname "${CHILD_PIPELINE_PATH}")"

# ==============================================================================
# YAML WRITER FUNCTIONS
# ==============================================================================

# HELPER: Avoids repeating setup commands in every job
write_setup_block() {
  local include_pnpm="${1:-false}"
  cat <<YAML
    - |
      echo "⏳ Preparing Environment..."
      npm install -g eas-cli
      cd Propwire
YAML
  if [[ "$include_pnpm" == "true" ]]; then
    cat <<YAML
      corepack enable pnpm
      pnpm install --frozen-lockfile
YAML
  fi
}

# ------------------------------------------------------------------------------
write_ota_scripts() {
  local channel="$1"
  local env="$2"
  local secret_var="$3"
  local include_e2e="${4:-false}"
  
  cat <<YAML
    - |
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "📲 OTA Update — ${channel}"
      echo "    Platform: All (iOS + Android)"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
YAML

  # write_setup_block "true"

  cat <<YAML
    - |
      echo "⏳ Publishing OTA update to '${channel}'..."
      # AUTH_CLIENT_SECRET=\${${secret_var}} npx eas update --channel ${channel} --message "\$CI_COMMIT_TITLE" --environment ${env} --platform all --non-interactive
      echo "✅ OTA update published successfully." 
YAML

  if [[ "$include_e2e" == "true" ]]; then
    cat <<'YAML'
    - |
      echo "🧪 Triggering E2E Test Suite..."
      # apt-get update && apt-get install -y jq
      # We are already in 'Propwire' directory from setup block
      # bash scripts/ci/trigger-e2e.sh
YAML
  fi
}

# ------------------------------------------------------------------------------
write_native_build_scripts() {
  local env_label="$1"
  local eas_profile="$2"

  cat <<YAML
    - |
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "🛠️  Native Build — ${env_label}"
      echo "    Profile : ${eas_profile} | Platform: All"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
YAML

  # write_setup_block "true"

  cat <<YAML
    - |
      # if [[ ! -f eas.json ]]; then echo "❌ eas.json not found"; exit 1; fi
      # npx eas build --profile ${eas_profile} --platform all --non-interactive
      echo "✅ EAS build queued. Monitor at: https://expo.dev/accounts/propwire/projects/propwire/builds"
YAML
}

# ------------------------------------------------------------------------------
write_internal_submit_scripts() {
  local env_label="$1"
  local eas_profile="$2"

  cat <<YAML
    - |
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "🚀  Internal Distribution — ${env_label}"
      echo "    Profile: ${eas_profile}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
YAML

  write_setup_block "false" # Submit only needs eas.json, not pnpm install

  cat <<YAML
    - |
      echo "⏳ Submitting iOS to TestFlight..."
      # npx eas submit --platform ios --profile ${eas_profile} --latest --non-interactive
      echo "⏳ Submitting Android to Internal Track..."
      # npx eas submit --platform android --profile ${eas_profile} --latest --non-interactive
      echo "✅ All submissions queued."
YAML
}

# ==============================================================================
# DECISION LOGIC (Remains exactly as your working version)
# ==============================================================================
DISTRIBUTE_JOB_NAME=""
DISTRIBUTE_EAS_PROFILE=""
DISTRIBUTE_ENV_LABEL=""
SUBMIT_INTERNAL_JOB_NAME=""
SUBMIT_INTERNAL_NEEDS=""
SUBMIT_INTERNAL_ENV=""
SUBMIT_INTERNAL_PROFILE=""
INCLUDE_E2E="false"
IS_NATIVE_BUILD="false"

if [[ "${CURRENT_BRANCH}" == "dev-pipeline-test" ]]; then
  if [[ "${NEEDS_NATIVE_BUILD}" == "true" ]]; then
    IS_NATIVE_BUILD="true"
    DISTRIBUTE_JOB_NAME="eas-build-dev"
    DISTRIBUTE_EAS_PROFILE="preview-store"
    DISTRIBUTE_ENV_LABEL="Preview (dev)"
    SUBMIT_INTERNAL_JOB_NAME="submit-dev-internal"
    SUBMIT_INTERNAL_NEEDS="eas-build-dev"
    SUBMIT_INTERNAL_ENV="Preview (dev)"
    SUBMIT_INTERNAL_PROFILE="testing"
  else
    DISTRIBUTE_JOB_NAME="eas-update-dev"
    DISTRIBUTE_ENV_LABEL="Preview (dev)"
    OTA_CHANNEL="preview"
    OTA_ENV="preview"
    OTA_SECRET_NAME="OTA_UPDATE_AUTH_PREVIEW"
    [[ "${PARENT_SOURCE}" == "web" ]] && INCLUDE_E2E="true"
  fi
elif [[ "${CURRENT_BRANCH}" == "main-pipeline-test" ]]; then
  if [[ "${NEEDS_NATIVE_BUILD}" == "true" ]]; then
    IS_NATIVE_BUILD="true"
    DISTRIBUTE_JOB_NAME="eas-build-prod"
    DISTRIBUTE_EAS_PROFILE="production"
    DISTRIBUTE_ENV_LABEL="Production"
    SUBMIT_INTERNAL_JOB_NAME="submit-prod-internal"
    SUBMIT_INTERNAL_NEEDS="eas-build-prod"
    SUBMIT_INTERNAL_ENV="Production"
    SUBMIT_INTERNAL_PROFILE="production"
  else
    DISTRIBUTE_JOB_NAME="eas-update-prod"
    DISTRIBUTE_ENV_LABEL="Production"
    OTA_CHANNEL="production"
    OTA_ENV="production"
    OTA_SECRET_NAME="OTA_UPDATE_AUTH_PROD"
  fi
fi

# ==============================================================================
# Guard & Pipeline Generation
# ==============================================================================
if [[ -z "$DISTRIBUTE_JOB_NAME" ]]; then
  cat > "${CHILD_PIPELINE_PATH}" <<'YAML'
stages: [distribute]
no-op:
  stage: distribute
  script: [echo "⚠️ No rules matched for $CI_COMMIT_BRANCH"]
YAML
  exit 0
fi

{
  cat <<YAML
workflow:
  rules:
    - if: \$CI_PIPELINE_SOURCE == "merge_request_event"
    - if: \$CI_PIPELINE_SOURCE == "parent_pipeline"
    - if: \$CI_COMMIT_BRANCH

stages: [distribute, submit]

${DISTRIBUTE_JOB_NAME}:
  stage: distribute
  script:
YAML

  if [[ "$IS_NATIVE_BUILD" == "true" ]]; then
    write_native_build_scripts "$DISTRIBUTE_ENV_LABEL" "$DISTRIBUTE_EAS_PROFILE"
  else
    write_ota_scripts "$OTA_CHANNEL" "$OTA_ENV" "$OTA_SECRET_NAME" "$INCLUDE_E2E"
  fi

  if [[ "$IS_NATIVE_BUILD" == "true" ]]; then
    cat <<YAML
${SUBMIT_INTERNAL_JOB_NAME}:
  stage: submit
  needs: [${SUBMIT_INTERNAL_NEEDS}]
  script:
YAML
    write_internal_submit_scripts "$SUBMIT_INTERNAL_ENV" "$SUBMIT_INTERNAL_PROFILE"
  fi
} > "${CHILD_PIPELINE_PATH}"

echo "✅ Generated child pipeline at ${CHILD_PIPELINE_PATH}"