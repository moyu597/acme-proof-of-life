module "app_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.project_name}-app"
  cidr = var.app_vpc_cidr
  azs  = var.azs

  private_subnets = [
    cidrsubnet(var.app_vpc_cidr, 4, 0),
    cidrsubnet(var.app_vpc_cidr, 4, 1),
  ]
  public_subnets = [
    cidrsubnet(var.app_vpc_cidr, 4, 8),
    cidrsubnet(var.app_vpc_cidr, 4, 9),
  ]

  # Single NAT gateway for both private subnets. The previous "no NAT, all
  # VPC endpoints" approach failed in practice — public image registries
  # (public.ecr.aws) and some elbv2 API paths aren't covered by interface
  # endpoints. One NAT ($4/week) is cheaper and more reliable.
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # ALB controller discovers subnets via these tags.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

module "edge_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.project_name}-edge"
  cidr = var.edge_vpc_cidr
  azs  = var.azs

  private_subnets = [
    cidrsubnet(var.edge_vpc_cidr, 4, 0),
    cidrsubnet(var.edge_vpc_cidr, 4, 1),
  ]

  enable_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true
}

# ---------- VPC peering ----------
resource "aws_vpc_peering_connection" "app_to_edge" {
  vpc_id      = module.app_vpc.vpc_id
  peer_vpc_id = module.edge_vpc.vpc_id
  auto_accept = true

  tags = { Name = "${var.project_name}-app-to-edge" }
}

resource "aws_route" "app_private_to_edge" {
  count                     = length(module.app_vpc.private_route_table_ids)
  route_table_id            = module.app_vpc.private_route_table_ids[count.index]
  destination_cidr_block    = var.edge_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_edge.id
}

resource "aws_route" "app_public_to_edge" {
  count                     = length(module.app_vpc.public_route_table_ids)
  route_table_id            = module.app_vpc.public_route_table_ids[count.index]
  destination_cidr_block    = var.edge_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_edge.id
}

resource "aws_route" "edge_to_app" {
  count                     = length(module.edge_vpc.private_route_table_ids)
  route_table_id            = module.edge_vpc.private_route_table_ids[count.index]
  destination_cidr_block    = var.app_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_edge.id
}

# ---------- VPC endpoints (replace the NAT gateway) ----------
resource "aws_security_group" "vpce" {
  name        = "${var.project_name}-vpce"
  description = "Allow HTTPS from inside the app VPC to interface endpoints."
  vpc_id      = module.app_vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.app_vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.app_vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.app_vpc.private_route_table_ids
}

locals {
  interface_endpoints = [
    "ecr.api",
    "ecr.dkr",
    "logs",
    "sts",
    "ec2",
    "ssm",
    "ssmmessages",
    "ec2messages",
    # The AWS Load Balancer Controller runs in the cluster and calls
    # elasticloadbalancing:* to provision/destroy ALBs. Without this
    # endpoint, ingresses get stuck with "i/o timeout" from the controller.
    "elasticloadbalancing",
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = module.app_vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.app_vpc.private_subnets
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
}
