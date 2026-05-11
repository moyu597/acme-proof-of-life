output "region" {
  value = var.region
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.acme.repository_url
  description = "Tag images and push here. Wire into GitHub Actions as ECR_REPOSITORY (without tag)."
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
  description = "Run this to put the cluster in your local kubeconfig."
}

output "edge_sql_private_ip" {
  value       = aws_instance.edge_sql.private_ip
  description = "Used as the SQL Server hostname inside the cluster connection string."
}

output "edge_sql_instance_id" {
  value       = aws_instance.edge_sql.id
  description = "Open an SSM Session Manager shell with: aws ssm start-session --target <id>"
}

# ---------------- Stakeholder credentials (sensitive) ----------------
# Each is plaintext in terraform.tfstate. Acceptable for a 2-week demo.
# Rotate or destroy at the end of the engagement.

output "cto_iam_username" {
  value = aws_iam_user.cto.name
}

output "cto_console_password" {
  value     = aws_iam_user_login_profile.cto.password
  sensitive = true
}

output "cto_access_key_id" {
  value     = aws_iam_access_key.cto.id
  sensitive = true
}

output "cto_secret_access_key" {
  value     = aws_iam_access_key.cto.secret
  sensitive = true
}

output "vp_iam_username" {
  value = aws_iam_user.vp.name
}

output "vp_console_password" {
  value     = aws_iam_user_login_profile.vp.password
  sensitive = true
}

output "vp_access_key_id" {
  value     = aws_iam_access_key.vp.id
  sensitive = true
}

output "vp_secret_access_key" {
  value     = aws_iam_access_key.vp.secret
  sensitive = true
}

output "console_signin_url" {
  value = "https://${local.account_id}.signin.aws.amazon.com/console"
}

output "sql_sa_password" {
  value     = random_password.sql_sa.result
  sensitive = true
  description = "Embedded in the k8s Secret. Surfaced here for direct sqlcmd access via SSM."
}

output "sql_readonly_password" {
  value     = random_password.sql_readonly.result
  sensitive = true
  description = "Login: stakeholder_readonly. SELECT-only against the AcmeDemo schema."
}
