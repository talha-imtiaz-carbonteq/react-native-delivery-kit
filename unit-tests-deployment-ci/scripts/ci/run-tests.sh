#!/usr/bin/env bash
set -euo pipefail

# Resolve to Propwire project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

echo "Node version: $(node -v)"

# Ensure pnpm is available
if command -v corepack >/dev/null 2>&1; then
  corepack enable >/dev/null 2>&1 || true
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm not found; installing..."
  npm i -g pnpm@9
fi

echo "pnpm version: $(pnpm -v)"

# Use a project-local pnpm store for efficient caching in CI
pnpm config set store-dir .pnpm-store

echo "Installing dependencies with pnpm..."
pnpm install --frozen-lockfile

echo "Running tests..."
if [[ "${CI:-}" == "true" ]]; then
  pnpm test:ci
else
  pnpm test
fi

echo "Tests completed."


