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

# Check if we're in the right context
if ! kubectl config current-context | grep -q "kind-management"; then
    echo "Error: Not connected to management cluster"
    echo "Run: kubectl config use-context kind-management"
    exit 1
fi

print_step "Initializing GitOps configuration..."

# For this demo, we'll use the local filesystem as the "git repo"
# In production, you would point to an actual git repository

# Get script directory BEFORE changing directories
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -d "$SCRIPT_DIR/manifests" ]; then
    echo "Error: manifests directory not found at $SCRIPT_DIR/manifests"
    echo "Please run this script from the crossplane-argocd directory or ensure manifests exist"
    exit 1
fi

# Create a local git repo to simulate the platform-repo
REPO_DIR="/tmp/platform-repo"
if [ -d "$REPO_DIR" ]; then
    print_warning "Platform repo already exists at $REPO_DIR, removing..."
    rm -rf "$REPO_DIR"
fi

print_step "Creating local platform repository..."
mkdir -p "$REPO_DIR"
cd "$REPO_DIR"

# Initialize git repo
git init
git config user.email "demo@example.com"
git config user.name "Demo User"

# Copy manifests to the repo
print_step "Copying manifests to repository..."
cp -r "$SCRIPT_DIR/manifests" "$REPO_DIR/"

# Create initial commit
git add .
git commit -m "Initial Crossplane XRDs and compositions"
print_success "Platform repository initialized at $REPO_DIR"

# Now create ArgoCD Applications that will watch the local repo
# We'll modify the ArgoCD apps to use local path instead of git
print_step "Creating ArgoCD Applications..."

# Create modified ArgoCD application for Crossplane config
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  source:
    repoURL: file://$REPO_DIR
    targetRevision: HEAD
    path: manifests/crossplane
    directory:
      recurse: false
      include: '{xrds/*.yaml,compositions/*.yaml}'

  destination:
    server: https://kubernetes.default.svc
    namespace: crossplane-system

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m

  ignoreDifferences:
    - group: apiextensions.crossplane.io
      kind: CompositeResourceDefinition
      jsonPointers:
        - /status
    - group: apiextensions.crossplane.io
      kind: Composition
      jsonPointers:
        - /status
EOF
print_success "crossplane-config Application created"

# Create ArgoCD application for cluster provisioning
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-provisioning
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  source:
    repoURL: file://$REPO_DIR
    targetRevision: HEAD
    path: manifests/crossplane/clusters
    directory:
      recurse: false
      include: '*.yaml'

  destination:
    server: https://kubernetes.default.svc
    namespace: crossplane-system

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m

  ignoreDifferences:
    - group: platform.io
      kind: BootstrapStack
      jsonPointers:
        - /status
        - /metadata/generation
        - /metadata/resourceVersion
EOF
print_success "cluster-provisioning Application created"

# Wait for ArgoCD to sync (automated sync policy will trigger)
print_step "Waiting for ArgoCD to sync XRDs and Compositions from Git..."
sleep 10

# Wait for XRDs to be established
print_step "Waiting for XRDs to be established..."
kubectl wait --for=condition=Established xrd/bootstrapstacks.platform.io --timeout=120s 2>/dev/null || \
  print_warning "XRD taking longer than expected (ArgoCD may still be syncing)"
print_success "XRDs are established"

# Check application status
print_step "Checking ArgoCD Application status..."
kubectl get applications -n argocd

echo ""
echo "=============================================="
echo -e "${GREEN}✓ GitOps Setup Complete!${NC}"
echo "=============================================="
echo ""
echo "Platform Repository: $REPO_DIR"
echo "ArgoCD Applications:"
echo "  - crossplane-config (XRDs and Compositions)"
echo "  - cluster-provisioning (Cluster XRs)"
echo ""
echo "Verify setup:"
echo "  kubectl get applications -n argocd"
echo "  kubectl get xrd"
echo "  kubectl get compositions"
echo ""
echo "Next steps:"
echo "  Run ./provision-clusters.sh to create cluster instances"
echo ""
