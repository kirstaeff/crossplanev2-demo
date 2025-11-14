#!/bin/bash

set -e
source "$(dirname "$0")/common.sh"

# Check if we're in the right context
if ! kubectl config current-context | grep -q "kind-management"; then
    print_error "Not connected to management cluster"
    echo "Run: kubectl config use-context kind-management"
    exit 1
fi

print_step "Initializing GitOps configuration with real GitLab repository..."

# Check if GitLab credentials are configured
if ! kubectl get secret gitlab-repo-creds -n argocd &> /dev/null; then
    print_error "GitLab repository credentials not found!"
    echo ""
    echo "Please run ./setup-gitlab-credentials.sh first to configure:"
    echo "  - GitLab repository URL"
    echo "  - GitLab username"
    echo "  - GitLab access token"
    exit 1
fi

# Get the repository URL from the secret
GITLAB_REPO_URL=$(kubectl get secret gitlab-repo-creds -n argocd -o jsonpath='{.data.url}' | base64 -d)

if [ -z "$GITLAB_REPO_URL" ]; then
    print_error "Could not retrieve GitLab repository URL from secret"
    exit 1
fi

print_success "Using GitLab repository: $GITLAB_REPO_URL"

# Get target revision/branch from environment or use default
TARGET_REVISION="${GIT_BRANCH:-main}"

print_step "Target branch: $TARGET_REVISION"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -d "$SCRIPT_DIR/gitops-demo/manifests" ]; then
    print_error "gitops-demo/manifests directory not found at $SCRIPT_DIR/gitops-demo/manifests"
    echo "Please ensure gitops-demo/manifests directory exists with your Crossplane configurations"
    exit 1
fi

echo ""
print_step "Creating ArgoCD Applications..."
echo ""

# Create ArgoCD application for Crossplane config (XRDs and Compositions)
print_step "Creating crossplane-config Application..."
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
    repoURL: $GITLAB_REPO_URL
    targetRevision: $TARGET_REVISION
    path: crossplane-argocd/gitops-demo/manifests/crossplane
    directory:
      recurse: true
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

print_step "Creating cluster-bootstrapping Application..."

cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-bootstrapping
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  source:
    repoURL: $GITLAB_REPO_URL
    targetRevision: $TARGET_REVISION
    path: crossplane-argocd/gitops-demo/manifests/crossplane/clusters
    directory:
      recurse: true
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

print_success "cluster-bootstrapping Application created"

echo ""
print_step "Waiting for ArgoCD to sync XRDs and Compositions from GitLab..."
sleep 10

print_step "Waiting for XRDs to be established..."
kubectl wait --for=condition=Established xrd/bootstrapstacks.platform.io --timeout=120s 2>/dev/null || \
  print_warning "XRD taking longer than expected (ArgoCD may still be syncing)"
print_success "XRDs are established"

echo ""
print_step "Checking ArgoCD Application status..."
kubectl get applications -n argocd

echo ""
echo -e "${GREEN} GitOps Setup Complete!${NC}"
echo ""
echo "GitLab Repository: $GITLAB_REPO_URL"
echo "Branch: $TARGET_REVISION"
echo ""
echo "ArgoCD Applications:"
echo "  - crossplane-config (XRDs and Compositions)"
echo "  - cluster-bootstrapping (Cluster XRs)"
echo ""
echo "Verify setup:"
echo "  kubectl get applications -n argocd"
echo "  kubectl get xrd"
echo "  kubectl get compositions"
echo ""
echo "Next steps:"
echo "  1. Push your gitops-demo directory to $GITLAB_REPO_URL"
echo "     cd $SCRIPT_DIR/.."
echo "     git init (if not already initialized)"
echo "     git remote add origin $GITLAB_REPO_URL"
echo "     git add crossplane-argocd/gitops-demo/"
echo "     git commit -m 'Initial Crossplane configuration'"
echo "     git push -u origin $TARGET_REVISION"
echo ""
echo "  2. Once pushed, ArgoCD will automatically sync"
echo ""
echo "  3. Run ./provision-clusters.sh to create cluster instances"
echo ""
