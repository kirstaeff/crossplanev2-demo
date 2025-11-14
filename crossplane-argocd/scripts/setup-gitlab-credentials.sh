#!/bin/bash

set -e
source "$(dirname "$0")/common.sh"

# Check if ArgoCD is installed
if ! kubectl get namespace argocd &> /dev/null; then
    print_error "ArgoCD namespace not found!"
    echo "Please run ./setup.sh first"
    exit 1
fi

# Get GitLab credentials from environment or prompt
if [ -z "$GITLAB_USERNAME" ]; then
    read -p "GitLab Username: " GITLAB_USERNAME
fi

if [ -z "$GITLAB_TOKEN" ]; then
    read -sp "GitLab Token (glpat-...): " GITLAB_TOKEN
    echo ""
fi

if [ -z "$GITLAB_REPO_URL" ]; then
    read -p "GitLab Repo URL (https://gitlab.com/...): " GITLAB_REPO_URL
fi

print_step "Setting up GitLab repository credentials for ArgoCD..."

# Create secret
kubectl create secret generic gitlab-repo-creds \
  -n argocd \
  --from-literal=url="$GITLAB_REPO_URL" \
  --from-literal=username="$GITLAB_USERNAME" \
  --from-literal=password="$GITLAB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Label it
kubectl label secret gitlab-repo-creds \
  -n argocd \
  argocd.argoproj.io/secret-type=repository \
  --overwrite

print_success "GitLab credentials configured for ArgoCD"

# Verify
print_step "Verifying connection..."
sleep 2

if kubectl get secret gitlab-repo-creds -n argocd &> /dev/null; then
    print_success "Secret created successfully"
    echo ""
    echo "Repository: $GITLAB_REPO_URL"
    echo "Username: $GITLAB_USERNAME"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Initialize your local git repository (if not already done):"
    echo "   cd $(pwd)"
    echo "   git init"
    echo "   git remote add origin $GITLAB_REPO_URL"
    echo ""
    echo "2. Ensure your manifests are committed to GitLab:"
    echo "   git add manifests/"
    echo "   git commit -m 'Initial Crossplane configuration'"
    echo "   git push -u origin main"
    echo ""
    echo "3. Run the GitOps initialization script:"
    echo "   ./init-gitops.sh"
    echo ""
else
    print_error "Failed to create secret"
    exit 1
fi
