#!/usr/bin/env bash
set -euo pipefail

# Resolve to Propwire project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

echo "Node version: $(node -v)"

if command -v corepack >/dev/null 2>&1; then
  corepack enable >/dev/null 2>&1 || true
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm not found; installing..."
  npm i -g pnpm@9
fi

echo "pnpm version: $(pnpm -v)"

pnpm config set store-dir .pnpm-store

echo "Installing dependencies with pnpm..."
pnpm install --frozen-lockfile

# echo "Running typecheck..."
pnpm typecheck

echo "Running audit..."
set +e
pnpm audit --audit-level=high
audit_exit_code=$?
set -e

if [[ $audit_exit_code -ne 0 ]]; then
  echo "Audit reported issues (non-blocking). Exit code: ${audit_exit_code}"
fi

echo "Running lint..."
set +e
pnpm lint
lint_exit_code=$?
set -e

if [[ $lint_exit_code -ne 0 ]]; then
  echo "Lint failed (non-blocking for now). Exit code: ${lint_exit_code}"
fi
