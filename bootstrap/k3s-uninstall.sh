#!/bin/bash
set -e
if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
  sudo /usr/local/bin/k3s-uninstall.sh
else
  echo "k3s-uninstall.sh in /usr/local/bin not found"
fi

rm -rf ~/.kube

sudo rm -rf /etc/rancher/k3s
sudo rm -rf /var/lib/rancher/k3s
sudo rm -rf /var/lib/kubelet
sudo rm -rf /var/lib/cni
sudo rm -rf /etc/cni
