#!/usr/bin/env bash
# Mirror the AWS Load Balancer Controller image from public ECR into the
# private ECR repo Terraform creates. Required because the cluster's
# private subnets can't reach public.ecr.aws.
#
# Run ONCE after `terraform apply` completes — the mirror persists.
#
#   ./scripts/mirror-alb-controller.sh
set -euo pipefail

REGION="${REGION:-us-east-1}"
TAG="${ALB_CONTROLLER_TAG:-v2.8.2}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PRIVATE_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
PRIVATE_REPO="${PRIVATE_REGISTRY}/aws-load-balancer-controller"

echo "Mirroring public.ecr.aws/eks/aws-load-balancer-controller:${TAG} -> ${PRIVATE_REPO}:${TAG}"

# Public ECR uses a different auth endpoint
aws ecr-public get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin public.ecr.aws

# Private ECR
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$PRIVATE_REGISTRY"

# Force amd64 — EKS nodes are x86_64. Apple Silicon Macs pull arm64 by default.
docker pull --platform linux/amd64 \
  "public.ecr.aws/eks/aws-load-balancer-controller:${TAG}"

docker tag "public.ecr.aws/eks/aws-load-balancer-controller:${TAG}" \
  "${PRIVATE_REPO}:${TAG}"

docker push "${PRIVATE_REPO}:${TAG}"

echo "Mirrored ${TAG} to ${PRIVATE_REPO}"
