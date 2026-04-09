# k8s - Raw Kubernetes Manifest

`microservice.yaml` is a minimal quick-start manifest for deploying SimpleTimeService directly to any Kubernetes cluster without Helm or ArgoCD.

It contains two resources:
- **Deployment** - 2 replicas, rolling update strategy, security context enforced (non-root, read-only filesystem, all capabilities dropped)
- **Service** - `ClusterIP` on port 80, forwarding to container port 8080

> For a production-style deployment with configurable values, HPA, PDB, and NetworkPolicy, use the Helm chart at [`charts/simple-time-service/`](../charts/simple-time-service/README.md). The ArgoCD GitOps path uses the Helm chart, not this manifest.

---

## Usage

```bash
# Deploy (resources go into your current kubectl namespace context, typically 'default')
kubectl apply -f k8s/microservice.yaml

# Verify
kubectl rollout status deployment/simple-time-service
kubectl get pods -l app=simple-time-service

# Access the service
kubectl port-forward svc/simple-time-service 8080:80
curl http://localhost:8080/
```

## Remove

```bash
kubectl delete -f k8s/microservice.yaml
```

> No namespace is specified in the manifest. Resources are deployed into whichever namespace your current kubectl context is set to. If you want a custom namespace, create it first and pass `-n <namespace>` to both commands.
