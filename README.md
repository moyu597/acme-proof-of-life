# Acme Proof of Life — Infrastructure as Code

The complete Terraform definition of the target-state Acme architecture from
**ADR 001** (modern cloud-native platform) and **ADR 003** (Enterprise Edge
isolation pattern). Every resource in the live demo environment was created
from the code in this repository — `terraform plan` against the running
environment produces zero drift.

The application stub, container manifests, and CI/CD glue are included as
context, but **the IaC under [`terraform/`](terraform/) is the substantive
deliverable.**

---

## The Terraform stack

| File | What it provisions |
|---|---|
| [`versions.tf`](terraform/versions.tf) | Provider versions pinned: AWS 6.x, Kubernetes 2.30+, Helm 2.13+. Default tags applied to every resource for cost attribution. |
| [`variables.tf`](terraform/variables.tf) | All knobs in one place — region, CIDRs, Kubernetes version, node instance types, capacity type (spot/on-demand), Edge SQL sizing. No hardcoded magic values elsewhere in the stack. |
| [`vpc.tf`](terraform/vpc.tf) | Two VPCs (`app` + `edge`) with non-overlapping CIDRs, peered together. App VPC has public + private subnets across 2 AZs, a NAT gateway, plus interface endpoints for ECR, STS, Logs, SSM, ELB, EC2 (kubelet egress to AWS APIs from private subnets). Edge VPC is private-by-default. **Mirrors ADR 003.** |
| [`eks.tf`](terraform/eks.tf) | EKS cluster (k8s 1.31) via the official `terraform-aws-modules/eks` v21 module. Managed node group with diversified spot capacity across `t3.medium`, `t3a.medium`, `t3.large`. IRSA enabled. Access entries map stakeholder IAM users to the cluster's read-only access policy. Bundled add-ons: `vpc-cni`, `kube-proxy`, `coredns`, `eks-pod-identity-agent`. |
| [`edge_sql.tf`](terraform/edge_sql.tf) | `t3.small` EC2 in the Edge VPC running SQL Server 2022 in Docker. Persistent EBS volume for the database files (encrypted gp3). SSM Session Manager for management (no SSH, no port 22 exposed). User-data script handles install, container start, schema bootstrap, and the read-only stakeholder login. |
| [`ecr.tf`](terraform/ecr.tf) | Private ECR repository for the application image. Lifecycle policy keeps the 10 most recent images. Image scanning on push. |
| [`alb_controller.tf`](terraform/alb_controller.tf) | AWS Load Balancer Controller installed via Helm. IRSA-bound IAM role with the published `iam_policy.json` + an inline patch for `ec2:GetSecurityGroupsForVpc` (a permission the v2.8.2 policy missed). Includes a private ECR mirror of the controller image because public registries aren't reachable from the private node subnets. |
| [`k8s_providers.tf`](terraform/k8s_providers.tf) | Kubernetes and Helm providers configured against the EKS cluster, using `exec` auth (`aws eks get-token`) so a fresh apply doesn't hit a chicken-and-egg auth problem before the cluster exists. |
| [`k8s_app.tf`](terraform/k8s_app.tf) | Application namespace, SQL connection Secret built from the EC2 private IP + generated SA password, and the stakeholder-view ClusterRole (`get/list/watch` only). |
| [`iam.tf`](terraform/iam.tf) | Two read-only IAM users (`acme-cto-readonly`, `acme-vp-readonly`) with `ReadOnlyAccess` managed policy + console passwords + access keys. Outputs marked sensitive. |
| [`observability.tf`](terraform/observability.tf) | CloudWatch log group, dashboard, and an alarm on Edge SQL CPU. |
| [`outputs.tf`](terraform/outputs.tf) | Every value a stakeholder needs to verify the environment — ALB DNS, cluster name, ECR repo URL, console sign-in URL, IAM user names + generated credentials (sensitive). |

---

## Architecture

```
                                Internet
                                    │
                                    ▼
                    ┌───────────────────────────────────┐
                    │  AWS Application Load Balancer    │
                    └───────────────┬───────────────────┘
                                    │
                ┌───────────────────┴───────────────────┐
                │                                       │
                │  App VPC  (10.0.0.0/16)               │
                │  ┌─────────────────────────────────┐  │
                │  │  EKS Cluster                    │  │
                │  │  ─ managed node group (spot)    │  │
                │  │  ─ acme-stub Deployment         │  │
                │  │  ─ AWS LB Controller (Helm)     │  │
                │  └─────────────────────────────────┘  │
                │                                       │
                │  VPC interface endpoints              │
                │  (ECR, STS, Logs, SSM, ELB, …)        │
                └───────────────┬───────────────────────┘
                                │
                       VPC peering (ADR 003)
                                │
                ┌───────────────┴───────────────────────┐
                │                                       │
                │  Edge VPC  (10.1.0.0/16)              │
                │  ┌─────────────────────────────────┐  │
                │  │  EC2 (t3.small)                 │  │
                │  │  Docker → SQL Server 2022       │  │
                │  │  Encrypted EBS                  │  │
                │  └─────────────────────────────────┘  │
                │                                       │
                │  SSM-only management (no SSH/22)      │
                └───────────────────────────────────────┘
```

See [`docs/architecture.md`](docs/architecture.md) for the full Mermaid
diagram and trust-boundary table.

---

## How the layers fit together

```
terraform/      →  Provisions AWS infrastructure + Kubernetes namespace/RBAC
   │
   └──→ outputs.tf surfaces ECR URL, cluster name, ALB DNS
            │
            ▼
   k8s/         →  Application Deployment / Service / Ingress (via Kustomize)
            │
            └──→ AWS Load Balancer Controller provisions an ALB
                     │
                     ▼
   app/         →  .NET 8 stub serving /admin (Razor) and /api/* (controllers)
                   Image built + pushed to ECR by scripts/deploy.sh or CI
            │
            └──→ Pod connects to SQL Server via VPC peering using a
                 Kubernetes Secret synthesized by terraform/k8s_app.tf
```

`scripts/deploy.sh` is the glue — pulls Terraform outputs, builds the image,
pushes to ECR, edits the Kustomization image reference, and kicks off the
rollout. The CI workflow at [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)
runs the same flow on every push to `main`.

---

## Operational decisions worth noting

| Decision | Rationale |
|---|---|
| **Spot nodes by default** | Diversified across 3 instance types so a single capacity event can't drain the cluster. Switch to on-demand with `node_capacity_type = "ON_DEMAND"`. |
| **EKS access entries, not the `aws-auth` ConfigMap** | Module v21+ default. The ConfigMap path is legacy and being deprecated by AWS. |
| **NAT gateway in the app VPC** | Necessary for nodes to pull public images and reach AWS APIs the interface endpoints don't cover. Single NAT (not per-AZ) keeps cost predictable. |
| **SQL Server on EC2 in a separate VPC, not RDS** | Mirrors ADR 003's Enterprise Edge pattern. In production the peering link is swapped for Direct Connect to the on-premises data centre; the application tier doesn't know the difference. |
| **Private ECR mirror for the ALB controller image** | Public ECR (`public.ecr.aws`) isn't covered by ECR VPC endpoints. Mirroring is the cleanest fix that keeps nodes' egress controlled. |
| **`security_group_additional_rules` for node→API on 443** | EKS module v21 doesn't include node-to-cluster-API ingress by default. Without this, kubelets can't register. |
| **`Encrypt=true` on the SQL connection string** | TLS on the wire even over private peering. `TrustServerCertificate=true` accepts the container's self-signed cert. |

---

## Repo layout

```
acme-proof-of-life/
├── terraform/                # The infrastructure (this is the deliverable)
├── app/                      # .NET 8 stub demonstrating the platform end-to-end
├── k8s/                      # Application Kubernetes manifests
├── scripts/
│   ├── deploy.sh             # Image → ECR → rollout pipeline (local + CI)
│   └── mirror-alb-controller.sh   # One-time public ECR → private ECR mirror
├── .github/workflows/        # CI: build + push + rollout on every push to main
└── docs/                     # Architecture diagram + deviations log
```

---

## Verifying against the live environment

Stakeholders with the read-only IAM credentials (provided separately) can
run `terraform plan` from a clean clone with their access keys configured.
The expected output is:

```
No changes. Your infrastructure matches the configuration.
```

That equivalence — code = running environment — is the point.
