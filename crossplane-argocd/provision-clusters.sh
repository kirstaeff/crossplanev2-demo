#!/bin/bash

set -e

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Check if we're in the right context
if ! kubectl config current-context | grep -q "kind-management"; then
    echo "Error: Not connected to management cluster"
    echo "Run: kubectl config use-context kind-management"
    exit 1
fi

# Check if GitLab credentials are configured
if ! kubectl get secret gitlab-repo-creds -n argocd &> /dev/null; then
    print_error "GitLab repository credentials not found!"
    echo "Please run ./setup-gitlab-credentials.sh and ./init-gitops.sh first"
    exit 1
fi

# Get the repository URL from the secret
GITLAB_REPO_URL=$(kubectl get secret gitlab-repo-creds -n argocd -o jsonpath='{.data.url}' | base64 -d)

# Get script directory and ensure we're working with the local git repo
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Check if this directory is a git repository
if [ ! -d ".git" ]; then
    print_error "This directory is not a git repository"
    echo "Please initialize git and push to GitLab first"
    exit 1
fi

echo "=============================================="
echo "Cluster Provisioning Demo"
echo "=============================================="
echo ""
echo "Repository: $GITLAB_REPO_URL"
echo ""

# Function to wait for BootstrapStack to be ready
wait_for_bootstrap() {
    local cluster_name=$1

    print_step "Waiting for $cluster_name bootstrap to complete..."

    # Use kubectl wait with jsonpath condition (simpler than manual loop)
    if kubectl wait --for=jsonpath='{.status.ready}'=true \
        bootstrapstack/"$cluster_name-cluster" \
        -n crossplane-system \
        --timeout=60s 2>/dev/null; then
        print_success "$cluster_name bootstrap complete!"
    else
        print_warning "$cluster_name bootstrap still in progress (this is expected with Crossplane reconciliation)"
    fi
}

# Provision prod cluster
print_step "Step 1: Provisioning PROD cluster..."
echo ""

# Show the manifest content
print_step "Prod cluster configuration (from GitLab repository):"
cat manifests/crossplane/clusters/prod-bootstrap.yaml

echo ""
print_step "Git log:"
git log --oneline -n 3

echo ""
print_step "ArgoCD will automatically sync (automated sync policy enabled)..."
print_success "Waiting for ArgoCD to detect and sync..."

# Wait for ArgoCD to sync (it polls every 3 minutes by default, but selfHeal is faster)
sleep 10

wait_for_bootstrap "prod"

echo ""
print_step "Checking prod cluster resources:"
echo ""
echo "On MANAGEMENT cluster - BootstrapStack:"
kubectl get bootstrapstack prod-cluster -n crossplane-system 2>/dev/null || echo "  (Still being created...)"
echo ""
echo "On MANAGEMENT cluster - Status tracking:"
kubectl get configmap -n crossplane-system -l managed-by=crossplane 2>/dev/null | grep "^prod-" || echo "  (Being provisioned...)"
echo ""
echo "On WORKLOAD cluster - Deployed namespaces and resources:"
kubectl --context kind-workload get namespaces | grep -E "monitoring|ingress|logging" || echo "  (Being provisioned...)"
kubectl --context kind-workload get configmap -n monitoring 2>/dev/null | grep "^prod-" || echo "  (Being provisioned...)"

echo ""
print_success "Prod cluster provisioning initiated"

# Wait a moment for resources to be created
sleep 5

# Provision staging cluster
echo ""
echo "=============================================="
print_step "Step 2: Provisioning STAGING cluster..."
echo ""

print_step "Staging cluster configuration (from GitLab repository):"
cat manifests/crossplane/clusters/staging-bootstrap.yaml

echo ""
print_step "Git log:"
git log --oneline -n 3

echo ""
print_step "ArgoCD automatically syncing staging cluster..."
print_success "Waiting for ArgoCD sync..."

sleep 10

wait_for_bootstrap "staging"

echo ""
print_step "Checking staging cluster resources:"
echo ""
echo "On MANAGEMENT cluster - BootstrapStack:"
kubectl get bootstrapstack staging-cluster -n crossplane-system 2>/dev/null || echo "  (Still being created...)"
echo ""
echo "On MANAGEMENT cluster - Status tracking:"
kubectl get configmap -n crossplane-system -l managed-by=crossplane 2>/dev/null | grep "^staging-" || echo "  (Being provisioned...)"
echo ""
echo "On WORKLOAD cluster - Deployed resources:"
kubectl --context kind-workload get configmap -n monitoring 2>/dev/null | grep "^staging-" || echo "  (Being provisioned...)"

echo ""
print_success "Staging cluster provisioning initiated"

# Final status
echo ""
echo "=============================================="
echo -e "${GREEN}✓ Cluster Provisioning Complete!${NC}"
echo "=============================================="
echo ""
echo "Provisioned clusters:"
kubectl get bootstrapstacks -n crossplane-system 2>/dev/null || true

echo ""
echo "MANAGEMENT cluster - All BootstrapStacks:"
kubectl get bootstrapstacks -n crossplane-system 2>/dev/null || true

echo ""
echo "MANAGEMENT cluster - Status tracking ConfigMaps:"
kubectl get configmap -n crossplane-system -l managed-by=crossplane 2>/dev/null || true

echo ""
echo "WORKLOAD cluster - Deployed namespaces:"
kubectl --context kind-workload get namespaces | grep -E "NAME|monitoring|ingress|logging" || true

echo ""
echo "WORKLOAD cluster - Resources in monitoring namespace:"
kubectl --context kind-workload get all,configmap -n monitoring 2>/dev/null || echo "  (Namespace being created...)"

echo ""
echo "Git commit history:"
git log --oneline

echo ""
echo "=============================================="
echo "Detailed status of PROD cluster:"
echo "=============================================="
kubectl describe bootstrapstack prod-cluster -n crossplane-system 2>/dev/null || echo "Still being created..."

echo ""
echo "=============================================="
echo "Verification commands:"
echo "=============================================="
echo "View all BootstrapStacks (management cluster):"
echo "  kubectl get bootstrapstacks -n crossplane-system"
echo ""
echo "View resources on WORKLOAD cluster:"
echo "  kubectl --context kind-workload get namespaces"
echo "  kubectl --context kind-workload get configmap -n monitoring"
echo "  kubectl --context kind-workload get configmap -n ingress-nginx"
echo "  kubectl --context kind-workload get configmap -n logging"
echo ""
echo "Describe prod cluster:"
echo "  kubectl describe bootstrapstack prod-cluster -n crossplane-system"
echo ""
echo "View Git history:"
echo "  git log"
echo ""
echo "View GitLab repository:"
echo "  $GITLAB_REPO_URL"
echo ""
echo "Switch between clusters:"
echo "  kubectl config use-context kind-management"
echo "  kubectl config use-context kind-workload"
echo ""
echo "Next steps:"
echo "  Run ./update-apps.sh to demonstrate GitOps updates"
echo ""
