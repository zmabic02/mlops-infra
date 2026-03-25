#!/bin/bash
set -e

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - \
  --write-kubeconfig-mode 644 \
  --disable=traefik \
  --disable=servicelb \
  --flannel-backend=host-gw \
  --disable-network-policy \
  --kube-apiserver-arg="service-account-issuer=https://kubernetes.default.svc.cluster.local"

sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(whoami):$(whoami) ~/.kube/config
chmod 600 ~/.kube/config
