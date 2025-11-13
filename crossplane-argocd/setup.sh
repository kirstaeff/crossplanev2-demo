#!/bin/bash

set -e

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper function for output
print_step() {
    echo -e "${BLUE}==> $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Check prerequisites
print_step "Checking prerequisites..."

if ! command -v kind &> /dev/null; then
    echo "kind is not installed. Please install kind first:"
    echo "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "kubectl is not installed. Please install kubectl first:"
    echo "https://kubernetes.io/docs/tasks/tools/"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo "helm is not installed. Please install helm first:"
    echo "https://helm.sh/docs/intro/install/"
    exit 1
fi

print_success "All prerequisites are installed"

echo ""
echo "=============================================="
echo "Creating 2 Kind Clusters"
echo "=============================================="
echo ""

# Delete existing clusters if they exist
if kind get clusters 2>/dev/null | grep -q "^management$"; then
    print_warning "Management cluster already exists. Deleting..."
    kind delete cluster --name management
    print_success "Deleted existing management cluster"
fi

if kind get clusters 2>/dev/null | grep -q "^workload$"; then
    print_warning "Workload cluster already exists. Deleting..."
    kind delete cluster --name workload
    print_success "Deleted existing workload cluster"
fi

# Create management cluster
print_step "Creating MANAGEMENT cluster with kind..."
kind create cluster --name management
print_success "Management cluster created"

# Switch to management context
kubectl config use-context kind-management

# Wait for management cluster to be ready
print_step "Waiting for management cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
print_success "Management cluster is ready"

# Create workload cluster
print_step "Creating WORKLOAD cluster with kind..."
kind create cluster --name workload
print_success "Workload cluster created"

# Switch to workload context
kubectl config use-context kind-workload

# Wait for workload cluster to be ready
print_step "Waiting for workload cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
print_success "Workload cluster is ready"

# Switch back to management cluster
kubectl config use-context kind-management

echo ""
print_step "Cluster Summary:"
kind get clusters
echo ""

# Extract workload cluster kubeconfig
print_step "Extracting workload cluster kubeconfig..."
kind get kubeconfig --name workload > /tmp/workload-kubeconfig.yaml
print_success "Workload kubeconfig saved to /tmp/workload-kubeconfig.yaml"

# Install Crossplane on management cluster
print_step "Installing Crossplane on management cluster..."
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

helm install crossplane \
    crossplane-stable/crossplane \
    --namespace crossplane-system \
    --create-namespace \
    --version 1.17.0 \
    --wait

print_success "Crossplane installed"

# Wait for Crossplane to be ready
print_step "Waiting for Crossplane pods to be ready..."
kubectl wait --for=condition=Available deployment/crossplane \
    -n crossplane-system --timeout=300s
kubectl wait --for=condition=Available deployment/crossplane-rbac-manager \
    -n crossplane-system --timeout=300s
print_success "Crossplane is ready"

# Install Crossplane Kubernetes provider
print_step "Installing Crossplane Kubernetes provider..."
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v0.14.1
EOF
print_success "Kubernetes provider installed"

# Wait for provider to be healthy
print_step "Waiting for Kubernetes provider to be ready..."
sleep 15
kubectl wait --for=condition=Healthy provider/provider-kubernetes --timeout=300s
print_success "Kubernetes provider is ready"

# Install Crossplane Helm provider
print_step "Installing Crossplane Helm provider..."
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-helm
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-helm:v0.19.0
EOF
print_success "Helm provider installed"

# Wait for Helm provider to be healthy
print_step "Waiting for Helm provider to be ready..."
sleep 15
kubectl wait --for=condition=Healthy provider/provider-helm --timeout=300s
print_success "Helm provider is ready"

# Install Crossplane function-patch-and-transform
print_step "Installing Crossplane function-patch-and-transform..."
cat <<EOF | kubectl apply -f -
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.6.0
EOF
print_success "Function installed"

# Wait for function to be ready
print_step "Waiting for function to be ready..."
sleep 10
kubectl wait --for=condition=Healthy function/function-patch-and-transform --timeout=300s 2>/dev/null || true
print_success "Function is ready"

# Create workload cluster secret in management cluster
print_step "Creating workload cluster kubeconfig secret..."
kubectl create secret generic workload-cluster-kubeconfig \
    -n crossplane-system \
    --from-file=kubeconfig=/tmp/workload-kubeconfig.yaml \
    --dry-run=client -o yaml | kubectl apply -f -
print_success "Workload cluster secret created"

# Configure Kubernetes provider to use workload cluster
print_step "Configuring Kubernetes provider for workload cluster..."
cat <<EOF | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: workload-cluster
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: workload-cluster-kubeconfig
      key: kubeconfig
EOF
print_success "Kubernetes provider configured for workload cluster"

# Configure Helm provider to use workload cluster
print_step "Configuring Helm provider for workload cluster..."
cat <<EOF | kubectl apply -f -
apiVersion: helm.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: workload-cluster
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: workload-cluster-kubeconfig
      key: kubeconfig
EOF
print_success "Helm provider configured for workload cluster"

# Install ArgoCD on management cluster
print_step "Installing ArgoCD on management cluster..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

print_success "ArgoCD installed"

# Wait for ArgoCD to be ready
print_step "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Available deployment/argocd-server \
    -n argocd --timeout=300s
kubectl wait --for=condition=Available deployment/argocd-repo-server \
    -n argocd --timeout=300s
kubectl wait --for=condition=Available deployment/argocd-applicationset-controller \
    -n argocd --timeout=300s
print_success "ArgoCD is ready"

# Register workload cluster in ArgoCD
print_step "Registering workload cluster in ArgoCD..."
kubectl config use-context kind-workload
WORKLOAD_CONTEXT="kind-workload"
argocd cluster add "$WORKLOAD_CONTEXT" \
    --kubeconfig /tmp/workload-kubeconfig.yaml \
    --name workload-cluster \
    --yes \
    --grpc-web \
    --insecure 2>/dev/null || print_warning "ArgoCD cluster registration skipped (manual step needed)"

kubectl config use-context kind-management

# Get ArgoCD admin password
print_step "Getting ArgoCD admin password..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
print_success "ArgoCD admin password retrieved"

# Port-forward ArgoCD (in background)
print_step "Setting up ArgoCD port-forward (background)..."
kubectl port-forward svc/argocd-server -n argocd 8080:443 --address=0.0.0.0 > /dev/null 2>&1 &
PORTFORWARD_PID=$!
echo $PORTFORWARD_PID > /tmp/argocd-portforward.pid
print_success "ArgoCD accessible at https://localhost:8080 (or https://<your-ip>:8080)"

echo ""
echo "=============================================="
echo -e "${GREEN}✓ Setup Complete!${NC}"
echo "=============================================="
echo ""
echo "Clusters Created:"
echo "  1. MANAGEMENT cluster (ArgoCD + Crossplane)"
echo "  2. WORKLOAD cluster (target for deployments)"
echo ""
echo "Current context: $(kubectl config current-context)"
echo ""
echo "ArgoCD URL: https://localhost:8080"
echo "ArgoCD Username: admin"
echo "ArgoCD Password: $ARGOCD_PASSWORD"
echo ""
echo "Switch between clusters:"
echo "  kubectl config use-context kind-management"
echo "  kubectl config use-context kind-workload"
echo ""
echo "Next steps:"
echo "  1. Run ./init-gitops.sh to setup GitOps"
echo "  2. Run ./provision-clusters.sh to provision workload apps"
echo ""
echo "To stop ArgoCD port-forward: kill \$(cat /tmp/argocd-portforward.pid)"
echo ""
