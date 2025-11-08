#!/usr/bin/env bash
set -euo pipefail
# Install Docker, kubectl, kind in a Codespace (Debian/Ubuntu).
# Usage: save as install-docker-kind.sh and run: bash install-docker-kind.sh

#######################
# Configuration
#######################
DOCKER_APT_REPO="https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-codespace-kind}"
TIMEOUT_DOCKER=60

#######################
# Helpers
#######################
log() { printf "\n[INFO] %s\n" "$*"; }
err() { printf "\n[ERROR] %s\n" "$*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "command '$1' not found; aborting."; exit 1; }
}

#######################
# Detect OS
#######################
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  os_name="$ID"
  os_like="$ID_LIKE"
else
  err "/etc/os-release not found; unsupported OS."
  exit 1
fi

if [[ "$os_name" != "ubuntu" && "$os_name" != "debian" && "$os_like" != *"debian"* ]]; then
  err "This script is written for Debian/Ubuntu based images. Detected: $os_name. Edit script for other distros."
  exit 1
fi

#######################
# Update & prerequisites
#######################
log "Updating apt and installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common

#######################
# Install Docker (if not present)
#######################
if command -v docker >/dev/null 2>&1; then
  log "docker CLI already installed"
else
  log "Installing Docker Engine (repo method)..."
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -y
  # Install packages. containerd.io may be provided as dependency.
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io
  log "Docker packages installed."
fi

# Ensure current user can run docker (non-login change may require reconnect)
if groups | grep -qw docker; then
  log "User is already in docker group."
else
  log "Adding current user to docker group (you may need to re-open session for group to take effect)."
  sudo usermod -aG docker "$USER" || true
fi

#######################
# Ensure a Docker daemon is running
#######################
if docker info >/dev/null 2>&1; then
  log "Docker daemon is running and accessible."
else
  log "Docker daemon not responding. Attempting to start dockerd in background (non-systemd mode)."
  # Try to start dockerd in the background. This may fail in restricted Codespaces.
  # Use a log file to aid debugging.
  DOCKER_LOG="/tmp/dockerd-codespace.log"
  sudo nohup dockerd >"$DOCKER_LOG" 2>&1 &

  log "Waiting up to ${TIMEOUT_DOCKER}s for dockerd to become available..."
  SECONDS_WAITED=0
  until docker info >/dev/null 2>&1; do
    sleep 1
    SECONDS_WAITED=$((SECONDS_WAITED+1))
    if [ "$SECONDS_WAITED" -ge "$TIMEOUT_DOCKER" ]; then
      err "Timed out waiting for dockerd. See $DOCKER_LOG for details."
      tail -n +1 "$DOCKER_LOG" | tail -n 60 || true
      err "If this fails in Codespaces, the environment may restrict starting a Docker daemon. See troubleshooting notes at end."
      exit 1
    fi
  done
  log "dockerd started and docker CLI is now usable."
fi

#######################
# Install kubectl (latest stable)
#######################
if command -v kubectl >/dev/null 2>&1; then
  log "kubectl already installed: $(kubectl version --client --short | tr -d '\n')"
else
  log "Downloading latest stable kubectl..."
  KUBECTL_STABLE="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_STABLE}/bin/linux/amd64/kubectl" -o /tmp/kubectl
  sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
  log "kubectl installed: $(kubectl version --client --short)"
fi

#######################
# Install kind (latest)
#######################
if command -v kind >/dev/null 2>&1; then
  log "kind already installed: $(kind --version)"
else
  log "Fetching latest kind release tag from GitHub..."
  KIND_LATEST_JSON="$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest)"
  KIND_TAG="$(printf '%s' "$KIND_LATEST_JSON" | grep -Po '"tag_name":\s*"\K(.*)(?=")')"
  if [[ -z "$KIND_TAG" ]]; then
    err "Couldn't determine latest kind release; aborting kind install."
    exit 1
  fi
  log "Latest kind release: $KIND_TAG"
  KIND_URL="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_TAG}/kind-linux-amd64"
  curl -fsSL "$KIND_URL" -o /tmp/kind
  sudo install -o root -g root -m 0755 /tmp/kind /usr/local/bin/kind
  rm -f /tmp/kind
  log "kind installed: $(kind --version)"
fi

#######################
# Create a kind cluster
#######################
if kind get clusters | grep -q "^${KIND_CLUSTER_NAME}$"; then
  log "kind cluster '${KIND_CLUSTER_NAME}' already exists."
else
  log "Creating kind cluster named '${KIND_CLUSTER_NAME}'..."
  # Basic cluster config — adjust nodeCount if you want
  cat <<'EOF' > /tmp/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
EOF

  # Create the cluster and wait (kind will use Docker)
  kind create cluster --name "${KIND_CLUSTER_NAME}" --config /tmp/kind-config.yaml
  kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"
  log "kind cluster '${KIND_CLUSTER_NAME}' created."
fi

#######################
# Final verification
#######################
log "Verification:"
docker version --format 'Client: {{.Client.Version}}, Server: {{.Server.Version}}' || true
kubectl version --client --short || true
kind --version || true
kubectl get nodes --context "kind-${KIND_CLUSTER_NAME}" --no-headers || true

log "All done. If everything worked, you have Docker, kubectl and kind available and a cluster called '${KIND_CLUSTER_NAME}'."

cat <<'NOTES'

Troubleshooting / Notes:
- Codespaces may restrict starting privileged daemons. If starting dockerd fails:
  * Check /tmp/dockerd-codespace.log for errors.
  * Consider using a Codespace devcontainer definition that includes Docker-in-Docker (dind) support or pre-built image that provides Docker.
  * Alternative lightweight options:
    - Use a remote Kubernetes cluster (e.g., a cloud cluster) and set KUBECONFIG to access it.
    - Use 'k3s' or 'microk8s' in environments that allow systemd (not typically possible in Codespaces).
    - Use GitHub Actions with kind for CI (common pattern) rather than running locally in Codespace.
- You may need to re-open your Codespace or re-login for group changes (docker group) to take effect:
  newgrp docker || true
NOTES

exit 0


#=====================================
# Metric-server Installation
#=====================================
#!/bin/bash

set -o errexit
set -o pipefail

METRICS_VERSION="v0.8.0"
NAMESPACE="kube-system"

echo "Installing Metrics Server ${METRICS_VERSION} for kind/Codespaces..."

# Apply official manifests
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_VERSION}/components.yaml

# Patch for kind/self-signed TLS + correct node IPs
kubectl -n ${NAMESPACE} patch deployment metrics-server \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname"}]'

# Wait until pod is ready
echo "Waiting for Metrics Server pod to be ready..."
kubectl -n ${NAMESPACE} wait --for=condition=available deployment metrics-server --timeout=60s

# Give the API a few seconds to start serving metrics
echo "Pausing 10 seconds to allow Metrics Server API to start..."
sleep 10

# Test Metrics API
echo "Testing Metrics API:"
kubectl top nodes
kubectl top pods --all-namespaces

echo "✅ Metrics Server installed and running!"


#=====================================
# NGINX ingress controller Installation
#=====================================
#!/bin/bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml
