#!/usr/bin/env bash
set -euo pipefail

# Resolve to Propwire project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

if command -v corepack >/dev/null 2>&1; then
  corepack enable >/dev/null 2>&1 || true
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm not found; installing..."
  npm i -g pnpm@9
fi

pnpm config set store-dir .pnpm-store
pnpm install --frozen-lockfile

# `eas build` has no --dry-run; `eas config` validates app.config + eas.json per profile/platform.
for profile in preview production; do
  for platform in ios android; do
    echo "EAS config check: profile=${profile} platform=${platform}"
    pnpm exec eas config -p "${platform}" -e "${profile}" --non-interactive >/dev/null
  done
done

echo "EAS config checks passed."
