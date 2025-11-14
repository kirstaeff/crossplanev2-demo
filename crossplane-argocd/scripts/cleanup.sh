#!/bin/bash

# Source common helper functions
source "$(dirname "$0")/common.sh"

echo "=============================================="
echo "Cleanup Demo Environment"
echo "=============================================="
echo ""

# Stop ArgoCD port-forward if running
if [ -f /tmp/argocd-portforward.pid ]; then
    print_step "Stopping ArgoCD port-forward..."
    PID=$(cat /tmp/argocd-portforward.pid)
    if ps -p $PID > /dev/null 2>&1; then
        kill $PID 2>/dev/null || true
        print_success "Port-forward stopped"
    fi
    rm -f /tmp/argocd-portforward.pid
fi

# Delete kind clusters
if kind get clusters 2>/dev/null | grep -q "^management$"; then
    print_step "Deleting management cluster..."
    kind delete cluster --name management
    print_success "Management cluster deleted"
else
    print_warning "Management cluster not found"
fi

if kind get clusters 2>/dev/null | grep -q "^workload$"; then
    print_step "Deleting workload cluster..."
    kind delete cluster --name workload
    print_success "Workload cluster deleted"
else
    print_warning "Workload cluster not found"
fi

# Remove local platform repository
REPO_DIR="/tmp/platform-repo"
if [ -d "$REPO_DIR" ]; then
    print_step "Removing platform repository..."
    rm -rf "$REPO_DIR"
    print_success "Platform repository removed"
fi

# Remove workload kubeconfig
if [ -f /tmp/workload-kubeconfig.yaml ]; then
    print_step "Removing workload kubeconfig..."
    rm -f /tmp/workload-kubeconfig.yaml
    print_success "Workload kubeconfig removed"
fi

echo ""
echo "=============================================="
echo -e "${GREEN}✓ Cleanup Complete!${NC}"
echo "=============================================="
echo ""
echo "All demo resources have been removed."
echo ""
echo "To run the demo again:"
echo "  ./setup.sh"
echo ""
