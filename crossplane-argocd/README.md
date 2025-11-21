# ArgoCD Operates Crossplane - Bootstrap Demo

- [Private repo setup](https://argo-cd.readthedocs.io/en/latest/user-guide/private-repositories/)

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│                      MANAGEMENT CLUSTER                            │
│                    (kind-management context)                       │
│                                                                    │
│  ┌──────────────┐          ┌────────────────────────────┐          │
│  │   ArgoCD     │          │      Crossplane            │          │
│  │              │          │                            │          │
│  │ - Watches    │─────────>│ - XRDs & Compositions      │          │
│  │   Git repo   │          │ - BootstrapStack XRs       │          │
│  │ - Syncs      │          │ - Kubernetes Provider      │          │
│  │   manifests  │          │ - Helm Provider            │          │
│  └──────────────┘          └─────────────┬──────────────┘          │
│                                          │                         │
│                                          │ Uses kubeconfig         │
│                                          │ secret to access        │
│                                          │ workload cluster        │
└──────────────────────────────────────────┼─────────────────────────┘
                                           │
                                           │ Creates resources via
                                           │ Kubernetes API
                                           ▼
┌────────────────────────────────────────────────────────────────────┐
│                      WORKLOAD CLUSTER                              │
│                    (kind-workload context)                         │
│                                                                    │
│  ┌──────────────────────────────────────────────────────┐          │
│  │  Namespaces:                                         │          │
│  │  ├── monitoring    (Prometheus ConfigMap)            │          │
│  │  ├── ingress-nginx (Nginx ConfigMap)                 │          │
│  │  └── logging       (Loki ConfigMap)                  │          │
│  │                                                      │          │
│  │  Resources created by Crossplane:                    │          │
│  │  - Namespaces                                        │          │
│  │  - ConfigMaps (simulating Helm releases)             │          │
│  │  - (In production: actual Helm charts, deployments)  │          │
│  └──────────────────────────────────────────────────────┘          │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### 3. GitOps Flow

```
Developer         Git Repository      ArgoCD           Crossplane        Kubernetes
    |                   |                |                  |                 |
    |-- git commit ---->|                |                  |                 |
    |                   |-- detect ----->|                  |                 |
    |                   |                |-- apply XR ----->|                 |
    |                   |                |                  |-- reconcile --->|
    |                   |                |                  |                 |
    |                   |                |<-- status -------|                 |
    |<-- git log -------|                |                  |                 |
```

## Verification Commands

### Switching Between Clusters

```bash
# View management cluster resources
kubectl config use-context kind-management
kubectl get bootstrapstacks -n crossplane-system
kubectl get providers -n crossplane-system

# View workload cluster resources
kubectl config use-context kind-workload
kubectl get namespaces
kubectl get configmap -n monitoring

# Or use --context flag
kubectl --context kind-management get xrd
kubectl --context kind-workload get configmap -n monitoring
```

### Management Cluster
```bash
# Ensure on management context
kubectl config use-context kind-management

# Check Crossplane components
kubectl get providers
kubectl get providerconfigs
kubectl get xrd
kubectl get compositions
kubectl get bootstrapstacks -n crossplane-system

# Check ArgoCD
kubectl get applications -n argocd
```

### Workload Cluster
```bash
# Ensure on workload context
kubectl config use-context kind-workload

# Check deployed resources
kubectl get namespaces
kubectl get all -n monitoring
kubectl get configmap -n monitoring
kubectl get configmap -n ingress-nginx
kubectl get configmap -n logging
```

### Cross-Cluster Check
```bash
# From management cluster, verify provider can access workload
kubectl describe providerconfig workload-cluster

# Check Crossplane Objects (these reference workload cluster)
kubectl get objects.kubernetes.crossplane.io -n crossplane-system

# Check their status
kubectl describe object prod-monitoring-config -n crossplane-system
```

## Troubleshooting

### Provider Can't Access Workload Cluster

```bash
# Check secret exists
kubectl get secret workload-cluster-kubeconfig -n crossplane-system

# Verify secret content
kubectl get secret workload-cluster-kubeconfig -n crossplane-system -o yaml

# Check ProviderConfig
kubectl describe providerconfig workload-cluster

# Check provider pods logs
kubectl logs -n crossplane-system -l pkg.crossplane.io/provider=provider-kubernetes
```

### Resources Not Appearing on Workload Cluster

```bash
# Check Crossplane Object status
kubectl get objects.kubernetes.crossplane.io -n crossplane-system
kubectl describe object <object-name> -n crossplane-system

# Look for errors in events
kubectl get events -n crossplane-system --sort-by='.lastTimestamp'

# Check provider health
kubectl get providers
kubectl describe provider provider-kubernetes
```

### Context Confusion

```bash
# Always check current context
kubectl config current-context

# List all contexts
kubectl config get-contexts

# Explicitly set context
kubectl config use-context kind-management
kubectl config use-context kind-workload
```

### XRD not established

```bash
kubectl get xrd
kubectl describe xrd bootstrapstacks.platform.io
```

### Composition not working

```bash
kubectl get compositions
kubectl describe composition bootstrap-stack
```

### BootstrapStack not creating resources

```bash
# Check the XR status
kubectl describe bootstrapstack prod-cluster -n crossplane-system

# Check Crossplane logs
kubectl logs -n crossplane-system -l app=crossplane

# Check function logs
kubectl logs -n crossplane-system -l pkg.crossplane.io/function=function-patch-and-transform
```

### ArgoCD not syncing

```bash
# Check Application status
kubectl get applications -n argocd
kubectl describe application crossplane-config -n argocd
kubectl describe application cluster-provisioning -n argocd

# Check ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller
```
