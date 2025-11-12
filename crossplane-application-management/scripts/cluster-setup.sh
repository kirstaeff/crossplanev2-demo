#!/bin/bash
set -e

echo "Crossplane v2 POC - Cluster Setup"
echo ""

echo ""
echo "Step 0: Configuring System Limits"
echo "----------------------------------"

# Display current limits
echo "Current limits:"
echo "  - File descriptors: $(ulimit -n)"
echo "  - Max user processes: $(ulimit -u)"

# Increase file descriptor limits for current session
ulimit -n 65536 2>/dev/null || echo "  ⚠ Warning: Could not set ulimit -n (may need sudo)"

# Increase max user processes
ulimit -u 65536 2>/dev/null || echo "  ⚠ Warning: Could not set ulimit -u (may need sudo)"

echo ""
echo "New limits:"
echo "  - File descriptors: $(ulimit -n)"
echo "  - Max user processes: $(ulimit -u)"

# Check and suggest system-wide inotify limits
echo ""
echo "Checking inotify limits (important for multiple clusters)..."
CURRENT_WATCHES=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo "unknown")
CURRENT_INSTANCES=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo "unknown")

echo "  - Current max_user_watches: $CURRENT_WATCHES"
echo "  - Current max_user_instances: $CURRENT_INSTANCES"

if [ "$CURRENT_WATCHES" != "unknown" ] && [ "$CURRENT_WATCHES" -lt 524288 ]; then
    echo ""
    echo "  ⚠ WARNING: inotify watches might be too low for 3 kind clusters."
    echo "  To increase, run these commands (requires sudo):"
    echo "    sudo sysctl -w fs.inotify.max_user_watches=524288"
    echo "    sudo sysctl -w fs.inotify.max_user_instances=512"
    echo "    sudo sysctl -p"
    echo ""
    read -p "  Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Setup cancelled. Please increase system limits and try again."
        exit 1
    fi
fi
echo ""

echo ""
echo "Step 1: Creating Cluster 1 (Control Plane with Crossplane)"
echo ""

# Create cluster1 config
cat <<EOF >/tmp/cluster1-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cluster1
nodes:
  - role: control-plane
EOF

# Create cluster1
if kind get clusters | grep -q "^cluster1$"; then
  echo "Cluster1 already exists. Skipping creation."
else
  kind create cluster --config /tmp/cluster1-config.yaml
  echo "Cluster1 created successfully."
fi

echo ""
echo "Step 2: Creating Cluster 2 (Static Pattern Target)"
echo ""

# Create cluster2 config
cat <<EOF >/tmp/cluster2-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cluster2
nodes:
  - role: control-plane
  - role: worker
EOF

# Create cluster2
if kind get clusters | grep -q "^cluster2$"; then
  echo "Cluster2 already exists. Skipping creation."
else
  echo "Creating cluster2..."
  kind create cluster --config /tmp/cluster2-config.yaml
  if [ $? -eq 0 ]; then
    echo "✓ Cluster2 created successfully."
  else
    echo "✗ Failed to create cluster2. Check system resources and limits."
    exit 1
  fi
fi

# Wait a bit to let cluster2 stabilize
echo "Waiting for cluster2 to stabilize..."
sleep 5

echo ""
echo "Step 3: Creating Cluster 3 (Dynamic Pattern Target)"
echo ""

# Create cluster3 config
cat <<EOF >/tmp/cluster3-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cluster3
nodes:
  - role: control-plane
  - role: worker
EOF

# Create cluster3
if kind get clusters | grep -q "^cluster3$"; then
  echo "Cluster3 already exists. Skipping creation."
else
  echo "Creating cluster3..."
  kind create cluster --config /tmp/cluster3-config.yaml
  if [ $? -eq 0 ]; then
    echo "✓ Cluster3 created successfully."
  else
    echo "✗ Failed to create cluster3. Check system resources and limits."
    echo "You may need to:"
    echo "  1. Increase system limits (see Step 0 warnings)"
    echo "  2. Free up system resources"
    echo "  3. Try creating cluster3 manually later"
    read -p "Continue without cluster3? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi
fi

# Wait a bit to let cluster3 stabilize
echo "Waiting for cluster3 to stabilize..."
sleep 5

echo ""
echo "Step 4: Verifying Cluster Network"
echo "----------------------------------"

# Get cluster1 control-plane container IP
CLUSTER1_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cluster1-control-plane)
echo "Cluster1 control-plane IP: $CLUSTER1_IP"

# Get cluster2 control-plane container IP
CLUSTER2_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cluster2-control-plane)
echo "Cluster2 control-plane IP: $CLUSTER2_IP"

# Get cluster3 control-plane container IP
CLUSTER3_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cluster3-control-plane)
echo "Cluster3 control-plane IP: $CLUSTER3_IP"

# Get network name
NETWORK=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' cluster1-control-plane)
echo "All clusters are on Docker network: $NETWORK"

echo ""
echo "Step 5: Installing Crossplane v2 on Cluster 1"
echo "----------------------------------------------"

# Switch to cluster1
kubectl config use-context kind-cluster1

# Add Crossplane Helm repo
helm repo add crossplane-stable https://charts.crossplane.io/stable 2>/dev/null || true
helm repo update

# Install Crossplane
if kubectl get namespace crossplane-system &>/dev/null; then
  echo "Crossplane namespace already exists. Skipping installation."
else
  echo "Installing Crossplane..."
  helm install crossplane \
    --namespace crossplane-system \
    --create-namespace \
    crossplane-stable/crossplane \
    --wait
  echo "Crossplane installed successfully."
fi

echo ""
echo "Step 6: Installing Crossplane Providers on Cluster 1"
echo "-----------------------------------------------------"

# Install Kubernetes Provider
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.15.0
EOF

# Install Helm Provider
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-helm
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-helm:v0.19.0
EOF

echo "Waiting for providers to become healthy..."
sleep 10

# Wait for provider-kubernetes to be healthy
kubectl wait --for=condition=Healthy provider.pkg.crossplane.io/provider-kubernetes --timeout=300s || true

# Wait for provider-helm to be healthy
kubectl wait --for=condition=Healthy provider.pkg.crossplane.io/provider-helm --timeout=300s || true

echo ""
echo "=========================================="
echo "Cluster Setup Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  - Cluster1 (kind-cluster1): Crossplane control plane"
echo "  - Cluster2 (kind-cluster2): Static pattern target (1 CP + 1 Worker)"
echo "  - Cluster3 (kind-cluster3): Dynamic pattern target (1 CP + 1 Worker)"
echo "  - Network: $NETWORK"
echo "  - Cluster2 API server: https://cluster2-control-plane:6443"
echo "  - Cluster3 API server: https://cluster3-control-plane:6443"
echo ""
echo "Next steps:"
echo "  1. Run ./scripts/register-target-cluster.sh to register Cluster2 and Cluster3"
echo "  2. Deploy the XRDs and Compositions"
echo "  3. Deploy static pattern to cluster2"
echo "  4. Deploy dynamic pattern to cluster3"
echo ""
