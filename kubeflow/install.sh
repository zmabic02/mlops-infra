#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OVERLAY_DIR="${SCRIPT_DIR}/overlays/k3s"
DEFAULT_USER_RBAC_FILE="${OVERLAY_DIR}/patches/default-user-rbac.yaml"
DEFAULT_KUSTOMIZE_BIN="${HOME}/.local/bin/kustomize_5_2_1"
KUSTOMIZE_BIN=${KUSTOMIZE_BIN:-$DEFAULT_KUSTOMIZE_BIN}
KUBECTL_BIN=${KUBECTL_BIN:-kubectl}
RETRY_COUNT=${RETRY_COUNT:-5}
RETRY_SLEEP_SECONDS=${RETRY_SLEEP_SECONDS:-20}

if [[ ! -x "$KUSTOMIZE_BIN" ]]; then
  KUSTOMIZE_BIN=kustomize
fi

require_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required binary: $1" >&2
    exit 1
  fi
}

wait_for_deployment() {
  local namespace=$1
  local name=$2
  local timeout=${3:-600s}

  echo "Waiting for deployment/${name} in namespace ${namespace}..."
  "$KUBECTL_BIN" -n "$namespace" rollout status deployment/"$name" --timeout="$timeout"
}

wait_for_namespace() {
  local namespace=$1
  local attempts=${2:-60}
  local sleep_seconds=${3:-5}

  echo "Waiting for namespace/${namespace}..."
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$KUBECTL_BIN" get namespace "$namespace" >/dev/null 2>&1; then
      return 0
    fi

    sleep "$sleep_seconds"
  done

  echo "Namespace ${namespace} was not created in time." >&2
  return 1
}

apply_default_user_rbac() {
  echo "Applying fallback RBAC for the default Kubeflow profile..."
  "$KUBECTL_BIN" apply --server-side --force-conflicts -f "$DEFAULT_USER_RBAC_FILE"
}

require_binary "$KUSTOMIZE_BIN"
require_binary "$KUBECTL_BIN"

manifest_file=$(mktemp)
trap 'rm -f "$manifest_file"' EXIT

"$KUSTOMIZE_BIN" build "$OVERLAY_DIR" > "$manifest_file"

attempt=1
until "$KUBECTL_BIN" apply --server-side --force-conflicts -f "$manifest_file"; do
  if [[ $attempt -ge $RETRY_COUNT ]]; then
    echo "Kubeflow apply failed after ${RETRY_COUNT} attempts." >&2
    exit 1
  fi

  echo "Kubeflow apply failed, retrying in ${RETRY_SLEEP_SECONDS}s (${attempt}/${RETRY_COUNT})..." >&2
  attempt=$((attempt + 1))
  sleep "$RETRY_SLEEP_SECONDS"
done

wait_for_deployment cert-manager cert-manager 300s
wait_for_deployment cert-manager cert-manager-cainjector 300s
wait_for_deployment cert-manager cert-manager-webhook 300s

wait_for_deployment istio-system istiod 600s
wait_for_deployment istio-system istio-ingressgateway 600s

wait_for_deployment auth dex 300s
wait_for_deployment oauth2-proxy oauth2-proxy 300s

wait_for_deployment kubeflow admission-webhook-deployment 600s
wait_for_deployment kubeflow centraldashboard 600s
wait_for_deployment kubeflow jupyter-web-app-deployment 600s
wait_for_deployment kubeflow notebook-controller-deployment 600s
wait_for_deployment kubeflow profiles-deployment 600s
wait_for_namespace kubeflow-user-example-com 60 5
apply_default_user_rbac
wait_for_deployment kubeflow pvcviewer-controller-manager 600s
wait_for_deployment kubeflow volumes-web-app-deployment 600s

wait_for_deployment kubeflow mysql 900s
wait_for_deployment kubeflow metadata-grpc-deployment 900s
wait_for_deployment kubeflow metadata-writer 900s
wait_for_deployment kubeflow cache-server 900s
wait_for_deployment kubeflow seaweedfs 900s
wait_for_deployment kubeflow ml-pipeline 900s
wait_for_deployment kubeflow ml-pipeline-ui 900s
wait_for_deployment kubeflow ml-pipeline-persistenceagent 900s
wait_for_deployment kubeflow ml-pipeline-scheduledworkflow 900s
wait_for_deployment kubeflow ml-pipeline-viewer-crd 900s

echo
echo "Kubeflow install finished."
echo "Port-forward the dashboard with: make kubeflow-dash"
echo "Default login: user@example.com / 12341234"
echo "Apply MLflow afterwards with: make apply-mlflow-app"