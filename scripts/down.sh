#!/usr/bin/env bash
# Tears down the v2 Crossplane PoC.
# Usage: ./scripts/down.sh   (pass --purge to also remove the kind node image)
set -euo pipefail
export KIND_EXPERIMENTAL_PROVIDER=podman

echo "==> deleting kind cluster"
kind delete cluster --name crossplane-poc 2>/dev/null || true

echo "==> stopping LocalStack"
podman rm -f localstack >/dev/null 2>&1 || true

if [ "${1:-}" = "--purge" ]; then
  echo "==> removing kind node image"
  podman rmi -f "$(podman images --format '{{.Repository}}:{{.Tag}}' | grep '^kindest/node' | head -1)" 2>/dev/null || true
fi

echo "Down."
