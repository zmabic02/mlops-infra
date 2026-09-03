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

  if grep -qi microsoft /proc/version 2>/dev/null; then
    sudo NVIDIA_CTK_CONFIG_FILE_PATH=/usr/local/nvidia/toolkit/.config/nvidia-container-runtime/config.toml \
      nvidia-ctk config \
        --set nvidia-container-runtime.mode=cdi \
        --set nvidia-container-runtime.modes.cdi.default-kind=nvidia.com/gpu \
        --in-place

    for f in /usr/local/nvidia/toolkit/nvidia-container-runtime /usr/local/nvidia/toolkit/nvidia-container-runtime.cdi; do
      if [[ -f "$f" ]] && grep -q '/proc/modules' "$f"; then
        sudo tee "$f" >/dev/null <<EOF
#! /bin/sh
NVIDIA_CTK_CONFIG_FILE_PATH=/usr/local/nvidia/toolkit/.config/nvidia-container-runtime/config.toml \\
PATH=/usr/local/nvidia/toolkit:\$PATH \\
	exec "\$0.real" "\$@"
EOF
        sudo chmod +x "$f"
      fi
    done
  fi
fi

mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(whoami):$(whoami) ~/.kube/config
chmod 600 ~/.kube/config
