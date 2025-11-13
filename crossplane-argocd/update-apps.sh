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

REPO_DIR="/tmp/platform-repo"
if [ ! -d "$REPO_DIR" ]; then
    print_error "Platform repository not found at $REPO_DIR"
    echo "Please run ./init-gitops.sh first"
    exit 1
fi

echo "=============================================="
echo "GitOps Update Demo"
echo "=============================================="
echo ""

cd "$REPO_DIR"

# Show current state
print_step "Current prod cluster configuration:"
echo ""
cat manifests/crossplane/clusters/prod-bootstrap.yaml | grep -A 2 "monitoring:"

echo ""
print_step "Current deployed Prometheus version (on WORKLOAD cluster):"
kubectl --context kind-workload get configmap prod-monitoring -n monitoring -o jsonpath='{.data.version}' 2>/dev/null || echo "Not yet deployed"

echo ""
echo "=============================================="
print_step "Step 1: Updating Prometheus version in Git"
echo "=============================================="
echo ""

# Update the Prometheus version
print_step "Modifying prod-bootstrap.yaml..."
sed -i 's/prometheusVersion: "45.0.0"/prometheusVersion: "46.0.0"/' manifests/crossplane/clusters/prod-bootstrap.yaml

print_step "New configuration:"
cat manifests/crossplane/clusters/prod-bootstrap.yaml | grep -A 2 "monitoring:"

echo ""
print_step "Committing change to Git..."
git add manifests/crossplane/clusters/prod-bootstrap.yaml
git commit -m "prod: Update Prometheus to 46.0.0"

print_success "Change committed"

echo ""
print_step "Git history:"
git log --oneline -n 5

echo ""
print_step "Git diff of the change:"
git show HEAD --stat
git show HEAD

echo ""
echo "=============================================="
print_step "Step 2: ArgoCD Auto-Sync"
echo "=============================================="
echo ""

print_step "ArgoCD detects Git change and syncs automatically..."
print_step "No manual intervention needed (automated sync policy)"
print_success "Waiting for ArgoCD to sync..."

sleep 10

echo ""
print_step "Waiting for Crossplane to reconcile..."
sleep 5

echo ""
print_step "New Prometheus version on WORKLOAD cluster:"
kubectl --context kind-workload get configmap prod-monitoring -n monitoring -o jsonpath='{.data.version}' 2>/dev/null || echo "Still updating..."

echo ""
echo ""
print_step "Complete prod cluster status:"
kubectl describe bootstrapstack prod-cluster -n crossplane-system | grep -A 20 "Status:" || true

echo ""
echo "=============================================="
print_step "Step 3: Demonstrating rollback"
echo "=============================================="
echo ""

print_step "Current Git history:"
git log --oneline -n 5

echo ""
read -p "Press Enter to rollback to Prometheus 45.0.0..."

echo ""
print_step "Reverting the commit..."
git revert HEAD --no-edit

print_success "Rollback committed"

echo ""
print_step "Updated Git history:"
git log --oneline -n 5

echo ""
print_step "Configuration after rollback:"
cat manifests/crossplane/clusters/prod-bootstrap.yaml | grep -A 2 "monitoring:"

echo ""
print_step "ArgoCD automatically syncing rollback..."
print_success "Waiting for ArgoCD to detect rollback and sync..."

sleep 10

echo ""
print_step "Waiting for Crossplane to reconcile..."
sleep 5

echo ""
print_step "Prometheus version after rollback (WORKLOAD cluster):"
kubectl --context kind-workload get configmap prod-monitoring -n monitoring -o jsonpath='{.data.version}' 2>/dev/null || echo "Still updating..."

echo ""
echo ""
echo "=============================================="
echo -e "${GREEN}✓ GitOps Update Demo Complete!${NC}"
echo "=============================================="
echo ""
echo "What we demonstrated:"
echo "  1. Git commit: Updated Prometheus from 45.0.0 to 46.0.0"
echo "  2. ArgoCD sync: Applied changes from Git to cluster"
echo "  3. Crossplane reconciliation: Updated ConfigMaps"
echo "  4. Git rollback: Reverted to previous version"
echo "  5. Automatic reconciliation: Crossplane updated back to 45.0.0"
echo ""
echo "Complete audit trail:"
cd "$REPO_DIR"
git log --oneline

echo ""
echo "Key benefits demonstrated:"
echo "  ✓ All changes tracked in Git"
echo "  ✓ Complete audit trail (who, when, what)"
echo "  ✓ Easy rollback via Git revert"
echo "  ✓ Automatic reconciliation"
echo "  ✓ Declarative infrastructure"
echo ""
echo "Verification commands:"
echo "  View Git log: cd $REPO_DIR && git log"
echo "  View cluster: kubectl get bootstrapstacks -n crossplane-system"
echo "  View resources on WORKLOAD cluster: kubectl --context kind-workload get configmap -n monitoring"
echo "  Check version: kubectl --context kind-workload get configmap prod-monitoring -n monitoring -o jsonpath='{.data.version}'"
echo ""
