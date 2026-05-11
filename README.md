# Acme Proof of Life

Production-grade preview of the target-state Acme architecture: EKS on AWS,
Terraform, a Dockerised .NET 8 stub talking to SQL Server in a separate Edge
VPC over peering, GitHub Actions CI/CD, read-only stakeholder access.

```
Internet → ALB → EKS pods (acme-stub) ──peering──→ EC2 SQL Server (Edge VPC)
                       ↑
                       └──── GitHub Actions push ───── ECR
```

Full diagram and trust boundaries: [`docs/architecture.md`](docs/architecture.md).

---

## Once-only prerequisites

1. AWS account with billing enabled.
2. **Set a $100 budget alert** before anything else
   (Billing → Budgets → monthly cost budget at $100, alert at 50%, 75%, and 90%).
   Two-week demo expected burn is ~$108 at this repo's defaults.
3. Local tools (macOS — install via `brew install`):
   - `awscli` ≥ 2
   - `terraform` ≥ 1.6
   - `kubectl` ≥ 1.31
   - `kustomize`
   - `helm`
   - `docker` (Docker Desktop running)
   - `dotnet` SDK 8
4. `aws configure` with an IAM user that has `AdministratorAccess`
   (used only for the bootstrap apply — stakeholders get scoped users).
5. Verify: `aws sts get-caller-identity` returns your account.

After that, every step below is mechanical.

---

## The one-shot

```bash
cd terraform

# 1. Init providers + modules.
terraform init

# 2. Two-stage apply. The first target apply creates the EKS cluster
#    so the kubernetes + helm providers have something to authenticate
#    against on the next pass.
terraform apply -target=module.eks -auto-approve

# 3. Full apply (ALB controller via Helm, k8s namespace + RBAC + secret,
#    CloudWatch dashboard, IAM users, observability).
terraform apply -auto-approve

# 4. Capture outputs you'll need next.
export ECR_REPO=$(terraform output -raw ecr_repository_url)
export CLUSTER=$(terraform output -raw eks_cluster_name)
export REGION=$(terraform output -raw region)
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

# 5. First image build + rollout (after this, GitHub Actions takes over).
cd ..
IMAGE_TAG=$(git rev-parse --short HEAD 2>/dev/null || date +%s) \
  scripts/deploy.sh

# 6. Get the ALB URL.
kubectl -n acme get ingress acme-stub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'

# 7. Hit it.
ALB=$(kubectl -n acme get ingress acme-stub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl "http://$ALB/health"
curl "http://$ALB/api/customers"
open "http://$ALB/admin"
```

End-to-end on a clean account: ~25 minutes (EKS provisioning dominates).

---

## Wiring up GitHub Actions (one-time)

After the initial Terraform apply, push the repo to GitHub and add these
secrets under **Settings → Secrets and variables → Actions**:

| Secret | Source |
|---|---|
| `AWS_ACCESS_KEY_ID` | An IAM user with permissions to push to ECR + update the EKS deployment. The Terraform-admin user is fine for the demo; tighten in production. |
| `AWS_SECRET_ACCESS_KEY` | Same. |
| `AWS_REGION` | `us-east-1` |
| `EKS_CLUSTER_NAME` | `terraform output -raw eks_cluster_name` |
| `ECR_REPOSITORY` | `terraform output -raw ecr_repository_url` *without* the `account.dkr.ecr.region.amazonaws.com/` prefix — i.e. just `acme-proof-of-life`. |

Push to `main`. The Actions tab will show build → push → rollout
finishing in 4–6 minutes.

---

## Stakeholder access

Two scoped IAM users are created. Their console passwords + access keys
are emitted as **sensitive** Terraform outputs. Pull them and paste into
the Proof of Life Dashboard:

```bash
cd terraform

# Console URL (same for both)
terraform output -raw console_signin_url

# CTO
terraform output -raw cto_iam_username
terraform output -raw cto_console_password
terraform output -raw cto_access_key_id
terraform output -raw cto_secret_access_key

# VP Engineering
terraform output -raw vp_iam_username
terraform output -raw vp_console_password
terraform output -raw vp_access_key_id
terraform output -raw vp_secret_access_key

# Read-only SQL login (works through SSM port-forward or from inside the cluster)
terraform output -raw sql_readonly_password
```

What they get:

- **AWS Console** with `ReadOnlyAccess` → all services visible, nothing
  mutable.
- **EKS** view via access entry mapped to `AmazonEKSViewPolicy` +
  the in-cluster `stakeholder-view` ClusterRole. After
  `aws eks update-kubeconfig`, `kubectl get pods -n acme` works;
  `kubectl delete` is rejected by RBAC.
- **SQL** read-only via the `stakeholder_readonly` login
  (`GRANT SELECT ON SCHEMA::dbo`).

⚠️ The console passwords + access keys land in `terraform.tfstate` as
plaintext. State stays on your laptop (local backend). Acceptable for a
two-week demo. Destroy at the end of the engagement (`terraform destroy`)
or migrate to an S3 backend with encryption + DynamoDB locking if the
demo extends.

---

## SSH-less SQL Server access

```bash
# Open an interactive shell on the SQL Server EC2 (no port 22 needed).
aws ssm start-session \
  --target $(cd terraform && terraform output -raw edge_sql_instance_id) \
  --region us-east-1

# Inside the session — run an ad-hoc query.
sudo docker exec -it mssql /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$(aws ssm get-parameter ...)" -No \
  -Q "SELECT TOP 5 * FROM AcmeDemo.dbo.customers"
```

---

## Cost & teardown

One-week burn at this repo's default settings (spot nodes, **VPC endpoints
in place of a NAT gateway**, full observability):

| Component | Hourly | Weekly |
|---|---|---|
| EKS control plane | $0.10 | $16.80 |
| 2× t3.medium nodes (spot) | $0.026 | $4.20 |
| Edge SQL t3.small EC2 | $0.021 | $3.49 |
| Application Load Balancer | $0.023 | $4.78 |
| 8× VPC interface endpoints | $0.08 | $13.44 |
| EBS volumes (~70 GB gp3) | — | $1.30 |
| CloudWatch + Container Insights | — | $8–10 |
| ECR storage, data transfer, misc | — | ~$2 |
| **Total (repo default)** | | **~$54/week** |

How this lines up against the three reference configurations:

| Configuration | One-week cost | This repo |
|---|---|---|
| Full (on-demand nodes, NAT gateway, full observability) | ~$62 | flip `node_capacity_type = "ON_DEMAND"` and add a NAT |
| Cost-optimised (spot, no NAT, basic CloudWatch) | ~$38 | drop interface endpoints + put nodes in public subnets |
| Bare minimum (spot, smaller nodes, no NAT, basic CloudWatch, NLB) | ~$28 | additional swap to NLB + t3.small nodes |
| **What this repo actually deploys** | **~$54** | spot + private subnets + VPC endpoints (production-shape) |

The repo trades ~$13/week for a production-grade private-subnet topology:
nodes have no public IPs and reach ECR / SSM / logs via interface endpoints.
The original "$38 cost-optimised" line achieves its number by putting nodes
in public subnets — fine for a demo, but a worse story when the CTO asks
"how does traffic leave the cluster?"

For a two-week interview window: **~$108 expected, set the budget alert
to $100** (raise from the original $75 noted below).

Teardown:

```bash
cd terraform
terraform destroy -auto-approve
```

If `terraform destroy` hangs on the EKS module (it sometimes does because
the ALB controller leaves a Target Group behind), run:

```bash
kubectl delete ingress -n acme acme-stub --wait=true
kubectl delete deployment -n acme acme-stub --wait=true
terraform destroy -auto-approve
```

---

## Deviations from the original brief

Documented in [`docs/architecture.md`](docs/architecture.md). Short version:

1. SQL Server is on EC2 in an Edge VPC (matches ADR 003), not RDS.
2. No NAT gateway — VPC endpoints instead.
3. EKS auth uses access entries (v21 default), not the legacy
   `aws-auth` ConfigMap.

## Repo layout

```
acme-proof-of-life/
├── terraform/        # Everything below the k8s namespace
├── app/              # .NET 8 stub (health, customers, orders, /admin)
├── k8s/              # Deployment, Service, Ingress, RBAC (via kustomize)
├── scripts/deploy.sh # Image-to-cluster helper
├── .github/workflows # CI on push to main
└── docs/             # Architecture diagram + deviations
```
