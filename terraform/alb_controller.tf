# ------------------------------------------------------------------
# AWS Load Balancer Controller via Helm + IRSA. Required for the
# k8s Ingress to provision an ALB.
# ------------------------------------------------------------------

data "http" "alb_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.2/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.project_name}-alb-controller"
  description = "Permissions for the AWS Load Balancer Controller."
  policy      = data.http.alb_iam_policy.response_body
}

data "aws_iam_policy_document" "alb_controller_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.project_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume.json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# The v2.8.2 iam_policy.json predates ec2:GetSecurityGroupsForVpc being
# required. Without it, the controller fails ingress reconciliation with
# AccessDenied. Patched in as an inline policy so it survives a state rebuild.
resource "aws_iam_role_policy" "alb_controller_extra" {
  name = "alb-controller-extra"
  role = aws_iam_role.alb_controller.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:GetSecurityGroupsForVpc"]
      Resource = "*"
    }]
  })
}

resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller.arn
    }
  }
}

# Private ECR mirror of the ALB controller image. Required because nodes
# live in private subnets without internet egress and can't reach
# public.ecr.aws. The mirror is populated out-of-band (see scripts/mirror-alb-controller.sh).
resource "aws_ecr_repository" "alb_controller" {
  name                 = "aws-load-balancer-controller"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.2"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "false"
  }
  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.alb_controller.metadata[0].name
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = module.app_vpc.vpc_id
  }

  # Override the default public.ecr.aws image with our private mirror.
  # Pull/push the image once before applying:
  #   scripts/mirror-alb-controller.sh
  set {
    name  = "image.repository"
    value = aws_ecr_repository.alb_controller.repository_url
  }
  set {
    name  = "image.tag"
    value = "v2.8.2"
  }

  depends_on = [
    aws_iam_role_policy_attachment.alb_controller,
    kubernetes_service_account.alb_controller,
    aws_ecr_repository.alb_controller,
  ]
}
