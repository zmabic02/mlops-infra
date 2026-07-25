#!/bin/bash
set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
  echo "GPU bootstrap currently supports Debian/Ubuntu hosts only." >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit nvidia-container-runtime

if ! command -v nvidia-container-runtime >/dev/null 2>&1; then
  echo "nvidia-container-runtime was not installed successfully." >&2
  exit 1
fi

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  echo "nvidia-ctk was not installed successfully." >&2
  exit 1
fi

# On WSL2 the NVIDIA driver libraries (libnvidia-ml.so, libcuda.so, ...) live
# under /usr/lib/wsl/lib rather than the standard Linux driver locations, so
# the legacy/"auto" nvidia-container-runtime injection mechanism can't find
# them and containers fail NVML init with ERROR_LIBRARY_NOT_FOUND. The
# officially documented fix is to force CDI (Container Device Interface) mode,
# which generates an explicit device spec pointing at the real library paths.
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "Detected WSL2 kernel; configuring nvidia-container-runtime for CDI mode."
  sudo mkdir -p /var/run/cdi
  sudo nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml
  sudo nvidia-ctk config --set nvidia-container-runtime.mode=cdi --in-place
  # k3s's own toolkit-managed config (used by the wrapper scripts it
  # generates under /usr/local/nvidia/toolkit) defaults default-kind to
  # "management.nvidia.com/gpu" instead of "nvidia.com/gpu", which breaks
  # CDI device resolution unless callers fully-qualify the device name
  # (handled via NVIDIA_VISIBLE_DEVICES=nvidia.com/gpu=all on the device
  # plugin pod). The k3s-managed nvidia-container-runtime wrapper scripts
  # also need their WSL2 /proc/modules fallback stripped; that is handled
  # in bootstrap/k3s-install.sh after k3s generates them.
fi