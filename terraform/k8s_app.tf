# ------------------------------------------------------------------
# Application namespace, DB credentials secret, and stakeholder RBAC.
# The Deployment / Service / Ingress are applied via kubectl in the
# README runbook so the image tag can be set from the CI pipeline.
# ------------------------------------------------------------------

resource "kubernetes_namespace" "acme" {
  metadata { name = "acme" }
}

resource "kubernetes_secret" "db" {
  metadata {
    name      = "acme-db-creds"
    namespace = kubernetes_namespace.acme.metadata[0].name
  }

  data = {
    # TLS-on-the-wire to SQL Server. TrustServerCertificate=true accepts the
    # container's self-signed cert (acceptable for a private-VPC demo); the
    # transport is still encrypted, which is what the audit cares about.
    "connection-string" = "Server=${aws_instance.edge_sql.private_ip},1433;Database=AcmeDemo;User Id=sa;Password=${random_password.sql_sa.result};Encrypt=true;TrustServerCertificate=true"
  }

  type = "Opaque"
}

# Stakeholder-scoped read-only role in the acme namespace, on top of
# the cluster-wide AmazonEKSViewPolicy granted via access entries.
resource "kubernetes_cluster_role" "stakeholder_view" {
  metadata { name = "stakeholder-view" }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "endpoints", "configmaps", "events", "namespaces", "nodes"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch"]
  }
}
