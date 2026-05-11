variable "project_name" {
  type        = string
  default     = "acme-proof-of-life"
  description = "Name prefix applied to all created resources."
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region. us-east-1 is cheapest and most service-rich for this demo."
}

variable "azs" {
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
  description = "EKS requires at least 2 availability zones."
}

variable "app_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "edge_vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "kubernetes_version" {
  type        = string
  default     = "1.31"
  description = "EKS control plane version. Update once per quarter."
}

variable "node_instance_types" {
  type        = list(string)
  default     = ["t3.medium", "t3a.medium", "t3.large"]
  description = "Diversified spot capacity pool."
}

variable "node_capacity_type" {
  type        = string
  default     = "SPOT"
  description = "Set to ON_DEMAND if you want zero interruption risk for the demo."
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "edge_sql_instance_type" {
  type    = string
  default = "t3.small"
}

variable "edge_sql_volume_size_gb" {
  type    = number
  default = 30
}
