#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> remove old docker packages if present"
sudo apt remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc || true

echo "==> install dependencies"
sudo apt install -y ca-certificates curl

echo "==> prepare keyrings"
sudo install -m 0755 -d /etc/apt/keyrings

echo "==> remove old docker repo files"
sudo rm -f /etc/apt/sources.list.d/docker.list
sudo rm -f /etc/apt/sources.list.d/docker.sources
sudo rm -f /etc/apt/keyrings/docker.asc

echo "==> download docker gpg key"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

ARCH="$(dpkg --print-architecture)"
. /etc/os-release
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

echo "==> create docker.sources"
cat <<EOF | sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

echo "==> apt update"
sudo apt update

echo "==> install docker"
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> enable and start docker"
sudo systemctl enable docker
sudo systemctl start docker

echo "==> docker version"
docker --version
docker compose version

echo "==> done"