#!/bin/bash
set -euo pipefail

install_k3s_exec="server"

if [[ "${ENABLE_GPU:-false}" == "true" ]]; then
  bash "$(dirname "$0")/nvidia-container-toolkit-install.sh"
  install_k3s_exec+=" --default-runtime nvidia"
fi

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$install_k3s_exec" sh -s - \
  --write-kubeconfig-mode 644 \
  --disable=traefik \
  --disable=servicelb \
  --disable-network-policy \
  --kube-apiserver-arg="service-account-issuer=https://kubernetes.default.svc.cluster.local"

if [[ "${ENABLE_GPU:-false}" == "true" ]]; then
  sudo grep -q nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml
fi

mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(whoami):$(whoami) ~/.kube/config
chmod 600 ~/.kube/config
