#!/usr/bin/env bash
# End-to-end "image-to-cluster" deploy. Used both locally (for the first
# rollout) and by GitHub Actions on every push to main.
#
#   ECR_REPO=<account>.dkr.ecr.us-east-1.amazonaws.com/acme-proof-of-life
#   IMAGE_TAG=<git-sha>
#   CLUSTER=acme-proof-of-life
#   REGION=us-east-1
set -euo pipefail

: "${ECR_REPO:?ECR_REPO required (Terraform output ecr_repository_url)}"
: "${IMAGE_TAG:?IMAGE_TAG required (typically the git SHA)}"
: "${CLUSTER:=acme-proof-of-life}"
: "${REGION:=us-east-1}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ECR_REPO%%/*}"

docker build --platform linux/amd64 \
  -t "$ECR_REPO:$IMAGE_TAG" \
  -t "$ECR_REPO:latest" \
  "$ROOT/app"

docker push "$ECR_REPO:$IMAGE_TAG"
docker push "$ECR_REPO:latest"

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

# ConfigMap with account-specific context used by the app for deep-link
# bookmarks. Created/refreshed every deploy so the source repo never
# carries an AWS account ID.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
# Edge SQL EC2 instance ID — used by the admin page for the SSM port-forward
# bookmark. Found by tag rather than hardcoded so a fresh deploy works without
# manual lookup.
EDGE_SQL_INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=$CLUSTER-edge-sql" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

kubectl -n acme create configmap acme-app-context \
  --from-literal=account-id="$ACCOUNT_ID" \
  --from-literal=region="$REGION" \
  --from-literal=cluster-name="$CLUSTER" \
  --from-literal=edge-sql-instance-id="$EDGE_SQL_INSTANCE_ID" \
  --dry-run=client -o yaml | kubectl apply -f -

pushd "$ROOT/k8s" >/dev/null
kustomize edit set image "ACME_IMAGE_PLACEHOLDER=$ECR_REPO:$IMAGE_TAG"
kubectl apply -k .
popd >/dev/null

kubectl -n acme rollout status deployment/acme-stub --timeout=5m
kubectl -n acme get ingress acme-stub
