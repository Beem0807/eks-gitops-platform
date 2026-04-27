# Networking - AWS Load Balancer Controller and ExternalDNS

The `gitops/networking/` directory deploys two ArgoCD apps that together handle inbound traffic routing and DNS registration.

| File | What it deploys | Sync wave | Namespace |
|------|----------------|-----------|-----------|
| `ingress-controller/aws-load-balancer-controller.yaml` | AWS Load Balancer Controller v1.8.1 - provisions ALBs from Ingress resources | 1 | `kube-system` |
| `external-dns/external-dns.yaml` | ExternalDNS v1.15.0 - creates Route53 records from Ingress/Service annotations | 1 | `external-dns` |

Both run on core nodes and use IRSA for AWS API access.

---

## Prerequisites - ACM certificate

Every ALB Ingress in this platform redirects HTTP → HTTPS. The ALB controller discovers the certificate by matching the Ingress hostname against ACM-issued certs in the same region. **The certificate must be in `ISSUED` state before bootstrap** - if it is missing or still pending validation, the ALB listener cannot be created and all HTTPS endpoints will be unreachable.

A single wildcard certificate covers all platform subdomains:

```bash
# 1. Request the cert (run in the same region as the cluster)
aws acm request-certificate \
  --domain-name "*.platform.<your-domain>" \
  --validation-method DNS \
  --region ap-south-1

# 2. Get the CNAME validation record
aws acm describe-certificate \
  --certificate-arn <CertificateArn> \
  --region ap-south-1 \
  --query "Certificate.DomainValidationOptions[0].ResourceRecord"

# 3. Add that CNAME to your Route53 hosted zone, then wait for validation
aws acm wait certificate-validated \
  --certificate-arn <CertificateArn> \
  --region ap-south-1
```

No ARN needs to be set in Ingress annotations - the controller automatically selects the best matching certificate from ACM.

---

## How they work together

```
Git push → ArgoCD syncs Ingress resource
    │
    ▼
AWS Load Balancer Controller
    │  reads Ingress annotations
    │  provisions ALB in AWS
    ▼
ExternalDNS
    │  reads hostname from Ingress status
    │  creates/updates Route53 A record
    ▼
https://<service>.platform.<domain>  →  ALB  →  pod
```

Every service and the ArgoCD UI are exposed this way. The platform shares a single ALB per Ingress group (`platform-observability` for Prometheus/Grafana/Alertmanager, a separate ALB for ArgoCD and the application) to reduce AWS load balancer costs.

---

## AWS Load Balancer Controller

Watches `Ingress` resources with `ingressClassName: alb` and provisions an Application Load Balancer in the VPC. Also handles `TargetGroupBinding` resources for NLB target group registration.

| Setting | Value |
|---------|-------|
| Chart | `aws-load-balancer-controller` v1.8.1 (from `https://aws.github.io/eks-charts`) |
| Cluster name | `simple-eks` |
| VPC ID | injected from ArgoCD cluster secret annotation `vpc-id` |
| Region | injected from ArgoCD cluster secret label `region` |
| IRSA | `<cluster-name>-aws-load-balancer-controller-irsa` |

The IRSA role is provisioned by `terraform/aws-load-balancer-controller-irsa.tf` and grants the controller permissions to create/update/delete load balancers, target groups, listeners, and security group rules.

Verify the controller is running and its webhook is healthy:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=30
```

### Ingress annotations used across this platform

| Annotation | Value | Meaning |
|-----------|-------|---------|
| `alb.ingress.kubernetes.io/scheme` | `internet-facing` | Public ALB |
| `alb.ingress.kubernetes.io/target-type` | `ip` | Route directly to pod IPs (requires VPC CNI) |
| `alb.ingress.kubernetes.io/listen-ports` | `[{"HTTP":80},{"HTTPS":443}]` | Serve both ports |
| `alb.ingress.kubernetes.io/ssl-redirect` | `443` | Redirect HTTP → HTTPS |
| `alb.ingress.kubernetes.io/group.name` | `platform-observability` | Share one ALB across multiple Ingress resources |

---

## ExternalDNS

Watches `Ingress` and `Service` resources and creates or updates Route53 records to match their hostnames. Uses `policy: sync` - records are deleted when the Ingress/Service is removed.

| Setting | Value |
|---------|-------|
| Chart | `external-dns` v1.15.0 (from `https://kubernetes-sigs.github.io/external-dns/`) |
| Provider | `aws` |
| Sources | `ingress`, `service` |
| Domain filter | injected from ArgoCD cluster secret annotation `domain-name` |
| TXT owner ID | `<cluster-name>` - used to identify records owned by this cluster |
| Zone type | public only (`--aws-zone-type=public`) |
| IRSA | `<cluster-name>-external-dns-irsa` |

The IRSA role is provisioned by `terraform/external-dns-irsa.tf` and grants `route53:ChangeResourceRecordSets`, `route53:ListHostedZones`, and `route53:ListResourceRecordSets`.

The domain filter restricts ExternalDNS to only manage records within your hosted zone, preventing accidental changes to other domains.

Verify ExternalDNS is processing Ingress resources:

```bash
kubectl get pods -n external-dns -l app.kubernetes.io/name=external-dns
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=30
```

Check that a DNS record was created for a service:

```bash
# List all records managed by this cluster in Route53
aws route53 list-resource-record-sets \
  --hosted-zone-id <your-zone-id> \
  --query "ResourceRecordSets[?contains(Name, 'platform')]"
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Ingress stuck in `Pending` / no ALB created | Check LBC logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`. Confirm the IRSA role ARN is correct and the node has the right OIDC trust. |
| ALB created but returns 503 | Target group health checks failing. Confirm pods are `Running` and the health check path (`/health`) returns 200. |
| DNS not resolving | Check ExternalDNS logs for Route53 API errors. Confirm `domain-name` annotation on the ArgoCD cluster secret matches the actual hosted zone. |
| DNS resolves but certificate error | The ACM certificate must cover the hostname (wildcard `*.platform.<domain>` recommended). Check ALB listener certificate in the AWS console. |
| `kubectl get ingress` shows no `ADDRESS` | ALB provisioning in progress - takes 1–3 minutes. Check LBC logs for errors. |
