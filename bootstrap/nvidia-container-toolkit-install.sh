#!/bin/bash
set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
  echo "GPU bootstrap currently supports Debian/Ubuntu hosts only." >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit nvidia-container-runtime

if ! command -v nvidia-container-runtime >/dev/null 2>&1; then
  echo "nvidia-container-runtime was not installed successfully." >&2
  exit 1
fi