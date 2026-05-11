module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.project_name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = module.app_vpc.vpc_id
  subnet_ids               = module.app_vpc.private_subnets
  control_plane_subnet_ids = module.app_vpc.private_subnets

  endpoint_public_access  = true
  endpoint_private_access = true

  enable_irsa                              = true
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # The v21 module's primary cluster SG doesn't include node→API ingress by
  # default. Without this, kubelets can't register and the node group fails
  # with "Unhealthy nodes in the kubernetes cluster".
  security_group_additional_rules = {
    ingress_nodes_443 = {
      description                = "Node groups to cluster API"
      protocol                   = "tcp"
      from_port                  = 443
      to_port                    = 443
      type                       = "ingress"
      source_node_security_group = true
    }
  }

  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
  }

  eks_managed_node_groups = {
    primary = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

      labels = {
        workload = "acme-stub"
      }
    }
  }

  # Stakeholder IAM users get read-only access via EKS access entries +
  # the in-cluster ClusterRole defined in k8s_rbac.tf.
  access_entries = {
    cto = {
      principal_arn = aws_iam_user.cto.arn
      type          = "STANDARD"
      user_name     = aws_iam_user.cto.name
      policy_associations = {
        view = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
    vp = {
      principal_arn = aws_iam_user.vp.arn
      type          = "STANDARD"
      user_name     = aws_iam_user.vp.name
      policy_associations = {
        view = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}

# Allow the EKS node SG to reach the Edge SQL Server over 1433.
resource "aws_security_group_rule" "nodes_egress_to_edge_sql" {
  type              = "egress"
  from_port         = 1433
  to_port           = 1433
  protocol          = "tcp"
  security_group_id = module.eks.node_security_group_id
  cidr_blocks       = [var.edge_vpc_cidr]
  description       = "Allow nodes to reach Edge VPC SQL Server"
}
