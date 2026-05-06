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

describe_failed_deployment() {
  local namespace=$1
  local name=$2
  local service_account
  local replicaset

  echo >&2
  echo "Deployment rollout failed for ${namespace}/${name}. Collecting diagnostics..." >&2
  "$KUBECTL_BIN" -n "$namespace" describe deployment "$name" >&2 || true

  service_account=$("$KUBECTL_BIN" -n "$namespace" get deployment "$name" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)
  if [[ -n "$service_account" ]]; then
    echo >&2
    echo "ServiceAccount ${namespace}/${service_account}:" >&2
    "$KUBECTL_BIN" -n "$namespace" get serviceaccount "$service_account" >&2 || true
  fi

  replicaset=$(
    "$KUBECTL_BIN" -n "$namespace" get rs -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null \
      | awk -v deployment_name="$name" '$2 == deployment_name { print $1 }' \
      | tail -n 1
  )

  if [[ -n "$replicaset" ]]; then
    echo >&2
    echo "ReplicaSet ${namespace}/${replicaset}:" >&2
    "$KUBECTL_BIN" -n "$namespace" describe rs "$replicaset" >&2 || true
  fi

  echo >&2
  echo "Recent events in namespace ${namespace}:" >&2
  "$KUBECTL_BIN" -n "$namespace" get events --sort-by=.metadata.creationTimestamp | tail -n 30 >&2 || true
}

wait_for_deployment() {
  local namespace=$1
  local name=$2
  local timeout=${3:-600s}

  echo "Waiting for deployment/${name} in namespace ${namespace}..."
  if ! "$KUBECTL_BIN" -n "$namespace" rollout status deployment/"$name" --timeout="$timeout"; then
    describe_failed_deployment "$namespace" "$name"
    return 1
  fi
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

label_namespace_privileged() {
  local namespace=$1

  echo "Setting Pod Security labels on namespace/${namespace}..."
  "$KUBECTL_BIN" label namespace "$namespace" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged \
    --overwrite
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

label_namespace_privileged kubeflow
wait_for_deployment kubeflow admission-webhook-deployment 600s
wait_for_deployment kubeflow centraldashboard 600s
wait_for_deployment kubeflow jupyter-web-app-deployment 600s
wait_for_deployment kubeflow notebook-controller-deployment 600s
wait_for_deployment kubeflow profiles-deployment 600s
wait_for_namespace kubeflow-user-example-com 60 5
label_namespace_privileged kubeflow-user-example-com
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