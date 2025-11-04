#!/bin/bash
set -e

echo "=============================================="
echo "Registering Target Clusters with Crossplane"
echo "=============================================="
echo ""

# Check if kind clusters exist
if ! kind get clusters | grep -q "^cluster1$"; then
  echo "ERROR: cluster1 does not exist. Run ./scripts/cluster-setup.sh first."
  exit 1
fi

if ! kind get clusters | grep -q "^cluster2$"; then
  echo "ERROR: cluster2 does not exist. Run ./scripts/cluster-setup.sh first."
  exit 1
fi

if ! kind get clusters | grep -q "^cluster3$"; then
  echo "ERROR: cluster3 does not exist. Run ./scripts/cluster-setup.sh first."
  exit 1
fi

echo "Step 1: Extracting kubeconfigs"
echo "-------------------------------"

# Get cluster2 kubeconfig
kind get kubeconfig --name cluster2 >/tmp/cluster2-kubeconfig.yaml
echo "Cluster2 kubeconfig extracted to /tmp/cluster2-kubeconfig.yaml"

# Get cluster3 kubeconfig
kind get kubeconfig --name cluster3 >/tmp/cluster3-kubeconfig.yaml
echo "Cluster3 kubeconfig extracted to /tmp/cluster3-kubeconfig.yaml"

echo ""
echo "Step 2: Modifying kubeconfigs for container network"
echo "----------------------------------------------------"

# Replace localhost with container hostname for cluster2
sed -i 's|https://127.0.0.1:[0-9]*|https://cluster2-control-plane:6443|g' /tmp/cluster2-kubeconfig.yaml
sed -i 's|https://localhost:[0-9]*|https://cluster2-control-plane:6443|g' /tmp/cluster2-kubeconfig.yaml
echo "Cluster2 server address updated to: https://cluster2-control-plane:6443"

# Replace localhost with container hostname for cluster3
sed -i 's|https://127.0.0.1:[0-9]*|https://cluster3-control-plane:6443|g' /tmp/cluster3-kubeconfig.yaml
sed -i 's|https://localhost:[0-9]*|https://cluster3-control-plane:6443|g' /tmp/cluster3-kubeconfig.yaml
echo "Cluster3 server address updated to: https://cluster3-control-plane:6443"

echo ""
echo "Step 3: Creating namespace for provider configuration"
echo "------------------------------------------------------"

# Switch to cluster1
kubectl config use-context kind-cluster1

# Create crossplane-system namespace if it doesn't exist
kubectl create namespace crossplane-system --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "Step 4: Creating kubeconfig secrets in Cluster 1"
echo "-------------------------------------------------"

# Create secret with cluster2 kubeconfig
kubectl create secret generic cluster2-kubeconfig \
  --from-file=kubeconfig=/tmp/cluster2-kubeconfig.yaml \
  --namespace crossplane-system \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret 'cluster2-kubeconfig' created in namespace 'crossplane-system'"

# Create secret with cluster3 kubeconfig
kubectl create secret generic cluster3-kubeconfig \
  --from-file=kubeconfig=/tmp/cluster3-kubeconfig.yaml \
  --namespace crossplane-system \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret 'cluster3-kubeconfig' created in namespace 'crossplane-system'"

echo ""
echo "Step 5: Creating ProviderConfigs for Kubernetes Provider"
echo "---------------------------------------------------------"

# Wait for provider-kubernetes to be installed
echo "Waiting for provider-kubernetes to be ready..."
kubectl wait --for=condition=Healthy provider.pkg.crossplane.io/provider-kubernetes --timeout=60s || echo "Warning: Provider may not be fully ready yet"

# Create ProviderConfig for cluster2
cat <<EOF | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: cluster2-config
spec:
  credentials:
    source: Secret
    secretRef:
      name: cluster2-kubeconfig
      namespace: crossplane-system
      key: kubeconfig
EOF
echo "ProviderConfig 'cluster2-config' created for Kubernetes provider"

# Create ProviderConfig for cluster3
cat <<EOF | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: cluster3-config
spec:
  credentials:
    source: Secret
    secretRef:
      name: cluster3-kubeconfig
      namespace: crossplane-system
      key: kubeconfig
EOF
echo "ProviderConfig 'cluster3-config' created for Kubernetes provider"

echo ""
echo "Step 6: Creating ProviderConfigs for Helm Provider"
echo "---------------------------------------------------"

# Wait for provider-helm to be installed
echo "Waiting for provider-helm to be ready..."
kubectl wait --for=condition=Healthy provider.pkg.crossplane.io/provider-helm --timeout=60s || echo "Warning: Provider may not be fully ready yet"

# Create ProviderConfig for cluster2
cat <<EOF | kubectl apply -f -
apiVersion: helm.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: cluster2-config
spec:
  credentials:
    source: Secret
    secretRef:
      name: cluster2-kubeconfig
      namespace: crossplane-system
      key: kubeconfig
EOF
echo "ProviderConfig 'cluster2-config' created for Helm provider"

# Create ProviderConfig for cluster3
cat <<EOF | kubectl apply -f -
apiVersion: helm.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: cluster3-config
spec:
  credentials:
    source: Secret
    secretRef:
      name: cluster3-kubeconfig
      namespace: crossplane-system
      key: kubeconfig
EOF
echo "ProviderConfig 'cluster3-config' created for Helm provider"

echo ""
echo "Step 7: Verifying connectivity to target clusters"
echo "--------------------------------------------------"

# Test connectivity to cluster2
echo "Testing connectivity to Cluster 2..."
cat <<EOF | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha2
kind: Object
metadata:
  name: test-connectivity-cluster2
spec:
  providerConfigRef:
    name: cluster2-config
  forProvider:
    manifest:
      apiVersion: v1
      kind: Namespace
      metadata:
        name: crossplane-test-cluster2
EOF

# Test connectivity to cluster3
echo "Testing connectivity to Cluster 3..."
cat <<EOF | kubectl apply -f -
apiVersion: kubernetes.crossplane.io/v1alpha2
kind: Object
metadata:
  name: test-connectivity-cluster3
spec:
  providerConfigRef:
    name: cluster3-config
  forProvider:
    manifest:
      apiVersion: v1
      kind: Namespace
      metadata:
        name: crossplane-test-cluster3
EOF

echo "Test Objects created. Waiting for them to become Ready..."
sleep 5

# Check cluster2 connectivity
if kubectl get object.kubernetes.crossplane.io/test-connectivity-cluster2 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
  echo "✓ SUCCESS: Connectivity to Cluster 2 verified!"
  kubectl delete object.kubernetes.crossplane.io/test-connectivity-cluster2
  kubectl config use-context kind-cluster2
  kubectl delete namespace crossplane-test-cluster2 --ignore-not-found=true
  kubectl config use-context kind-cluster1
else
  echo "⚠ WARNING: Cluster 2 connectivity test may still be in progress."
fi

# Check cluster3 connectivity
if kubectl get object.kubernetes.crossplane.io/test-connectivity-cluster3 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
  echo "✓ SUCCESS: Connectivity to Cluster 3 verified!"
  kubectl delete object.kubernetes.crossplane.io/test-connectivity-cluster3
  kubectl config use-context kind-cluster3
  kubectl delete namespace crossplane-test-cluster3 --ignore-not-found=true
  kubectl config use-context kind-cluster1
else
  echo "⚠ WARNING: Cluster 3 connectivity test may still be in progress."
fi

echo ""
echo "=========================================="
echo "Registration Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Cluster 2 (Static Pattern):"
echo "    - Kubeconfig secret: cluster2-kubeconfig"
echo "    - ProviderConfig: cluster2-config"
echo "    - API endpoint: https://cluster2-control-plane:6443"
echo ""
echo "  Cluster 3 (Dynamic Pattern):"
echo "    - Kubeconfig secret: cluster3-kubeconfig"
echo "    - ProviderConfig: cluster3-config"
echo "    - API endpoint: https://cluster3-control-plane:6443"
echo ""
echo "Next steps:"
echo "  1. Deploy XRDs:"
echo "     kubectl apply -f manifests/xrd-static-cluster.yaml"
echo "     kubectl apply -f manifests/xrd-dynamic-cluster.yaml"
echo ""
echo "  2. Deploy Compositions:"
echo "     kubectl apply -f manifests/composition-static.yaml"
echo "     kubectl apply -f manifests/composition-dynamic.yaml"
echo ""
echo "  3. Deploy examples:"
echo "     kubectl apply -f examples/xr-static.yaml      # To cluster2"
echo "     kubectl apply -f examples/xr-dynamic.yaml     # To cluster3"
echo ""
