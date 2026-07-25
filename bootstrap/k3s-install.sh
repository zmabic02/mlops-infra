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

  # On WSL2 there are no real "nvidia" kernel modules (the driver is a stub
  # exposed by the Windows host via /dev/dxg), so the wrapper scripts that
  # k3s generates under /usr/local/nvidia/toolkit unconditionally fall back
  # to plain runc after checking `grep '^nvidia ' /proc/modules`, silently
  # skipping GPU/CDI injection regardless of nvidia-container-runtime.mode.
  # Strip that check so the wrappers always invoke the real CDI-aware binary.
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "Detected WSL2 kernel; patching k3s-managed nvidia-container-runtime wrappers to skip the /proc/modules check."
    # k3s gives its generated runtime wrapper a separate configuration file.
    # Its default CDI kind is management.nvidia.com/gpu, whereas the CDI spec
    # created by nvidia-ctk uses nvidia.com/gpu. Keep them aligned: otherwise
    # pods run with RuntimeClass nvidia fail before starting with an
    # "unresolvable CDI devices management.nvidia.com/gpu=all" error.
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
