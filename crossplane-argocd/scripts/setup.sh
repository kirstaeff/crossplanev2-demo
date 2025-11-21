#!/bin/bash

set -e

source "$(dirname "$0")/common.sh"

print_step "Checking prerequisites..."

if ! command -v kind &>/dev/null; then
  echo "kind is not installed. Please install kind first:"
  echo "https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
  exit 1
fi

if ! command -v kubectl &>/dev/null; then
  echo "kubectl is not installed. Please install kubectl first:"
  echo "https://kubernetes.io/docs/tasks/tools/"
  exit 1
fi

if ! command -v helm &>/dev/null; then
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

print_step "Creating MANAGEMENT cluster with kind..."
kind create cluster --name management
print_success "Management cluster created"

kubectl config use-context kind-management

print_step "Waiting for management cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
print_success "Management cluster is ready"

print_step "Creating WORKLOAD cluster with kind..."
kind create cluster --name workload
print_success "Workload cluster created"

kubectl config use-context kind-workload

print_step "Waiting for workload cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=60s
print_success "Workload cluster is ready"

kubectl config use-context kind-management

echo ""
print_step "Cluster Summary:"
kind get clusters
echo ""

print_step "Extracting workload cluster kubeconfig..."
kind get kubeconfig --name workload >/tmp/workload-kubeconfig.yaml

print_step "Modifying kubeconfig for container network..."
sed -i 's|https://127.0.0.1:[0-9]*|https://workload-control-plane:6443|g' /tmp/workload-kubeconfig.yaml
sed -i 's|https://localhost:[0-9]*|https://workload-control-plane:6443|g' /tmp/workload-kubeconfig.yaml
print_success "Kubeconfig server address updated to: https://workload-control-plane:6443"

print_step "Installing Crossplane on management cluster..."
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

helm install crossplane \
  crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace \
  --version 2.1.0 \
  --wait

print_success "Crossplane installed"

print_step "Waiting for Crossplane pods to be ready..."
kubectl wait --for=condition=Available deployment/crossplane \
  -n crossplane-system --timeout=300s
kubectl wait --for=condition=Available deployment/crossplane-rbac-manager \
  -n crossplane-system --timeout=300s
print_success "Crossplane is ready"

print_step "Installing Crossplane providers..."
kubectl apply -f ./manifests/crossplane/providers.yaml
print_success "Providers installed"

print_step "Waiting for providers to be ready..."
kubectl wait --for=condition=Healthy provider/provider-helm --timeout=300s
kubectl wait --for=condition=Healthy provider/provider-kubernetes --timeout=300s
print_success "Providers are ready"

print_step "Installing Crossplane functions..."
kubectl apply -f ./manifests/crossplane/functions.yaml
print_success "Functions installed"

print_step "Waiting for function to be ready..."
kubectl wait --for=condition=Healthy function/function-patch-and-transform --timeout=300s 2>/dev/null || true
kubectl wait --for=condition=Healthy function/crossplane-contrib-function-cel-filter --timeout=300s 2>/dev/null || true
print_success "Functions are ready"

print_step "Creating workload cluster kubeconfig secret..."
kubectl create secret generic workload-cluster-kubeconfig \
  -n crossplane-system \
  --from-file=kubeconfig=/tmp/workload-kubeconfig.yaml \
  --dry-run=client -o yaml | kubectl apply -f -
print_success "Workload cluster secret created"

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

print_step "Installing ArgoCD on management cluster..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

print_success "ArgoCD installed"

print_step "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Available deployment/argocd-server \
  -n argocd --timeout=300s
kubectl wait --for=condition=Available deployment/argocd-repo-server \
  -n argocd --timeout=300s
kubectl wait --for=condition=Available deployment/argocd-applicationset-controller \
  -n argocd --timeout=300s
print_success "ArgoCD is ready"

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

print_step "Getting ArgoCD admin password..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
print_success "ArgoCD admin password retrieved"

print_step "Setting up ArgoCD port-forward (background)..."
kubectl port-forward svc/argocd-server -n argocd 8080:443 --address=0.0.0.0 >/dev/null 2>&1 &
PORTFORWARD_PID=$!
echo $PORTFORWARD_PID >/tmp/argocd-portforward.pid
print_success "ArgoCD accessible at https://localhost:8080 (or https://<your-ip>:8080)"

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

kubectl create secret generic gitlab-repo-creds \
  -n argocd \
  --from-literal=url="$GITLAB_REPO_URL" \
  --from-literal=username="$GITLAB_USERNAME" \
  --from-literal=password="$GITLAB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret gitlab-repo-creds \
  -n argocd \
  argocd.argoproj.io/secret-type=repository \
  --overwrite

print_success "GitLab credentials configured for ArgoCD"

if kubectl get secret gitlab-repo-creds -n argocd &> /dev/null; then
    print_success "Secret created successfully"

echo ""
echo -e "${GREEN}✓ Setup Complete!${NC}"
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
echo ""
echo "To stop ArgoCD port-forward: kill \$(cat /tmp/argocd-portforward.pid)"
echo ""
