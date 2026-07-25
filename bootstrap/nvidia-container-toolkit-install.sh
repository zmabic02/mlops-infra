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

# On WSL2 there are no traditional "nvidia" kernel modules to detect (the GPU
# driver lives on the Windows host), so nvidia-container-runtime's default
# "auto" mode falls back to plain runc and silently skips GPU injection. WSL2
# requires the "csv" runtime mode (driven by host-files-for-container.d/*.csv)
# plus no-cgroups, since WSL2 doesn't expose real device cgroups either.
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "Detected WSL2 kernel; configuring nvidia-container-runtime for WSL (csv mode, no-cgroups)."
  sudo nvidia-ctk config --set nvidia-container-runtime.mode=csv --in-place
  sudo nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place
fi