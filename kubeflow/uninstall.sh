#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OVERLAY_DIR="${SCRIPT_DIR}/overlays/k3s"
DEFAULT_KUSTOMIZE_BIN="${HOME}/.local/bin/kustomize_5_2_1"
KUSTOMIZE_BIN=${KUSTOMIZE_BIN:-$DEFAULT_KUSTOMIZE_BIN}
KUBECTL_BIN=${KUBECTL_BIN:-kubectl}

if [[ ! -x "$KUSTOMIZE_BIN" ]]; then
  KUSTOMIZE_BIN=kustomize
fi

require_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required binary: $1" >&2
    exit 1
  fi
}

require_binary "$KUSTOMIZE_BIN"
require_binary "$KUBECTL_BIN"

manifest_file=$(mktemp)
trap 'rm -f "$manifest_file"' EXIT

"$KUSTOMIZE_BIN" build "$OVERLAY_DIR" > "$manifest_file"

"$KUBECTL_BIN" delete --ignore-not-found -f "$manifest_file" || true

"$KUBECTL_BIN" delete namespace kubeflow kubeflow-user-example-com auth oauth2-proxy istio-system cert-manager --ignore-not-found || true

echo "Kubeflow uninstall requested."
echo "If any namespace remains Terminating, inspect finalizers on the target cluster before retrying."