# HCL translation of k8s/secret.yaml. `data` (vs `data` being pre-base64-encoded, which the
# YAML manifest's `stringData` avoided needing) - the kubernetes_secret resource's `data`
# argument base64-encodes plain values automatically, same effect as stringData there.
resource "kubernetes_secret" "db" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "url-shortener-db"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  data = {
    DB_NAME     = var.db_name
    DB_USER     = var.db_user
    DB_PASSWORD = var.db_password
  }

  type = "Opaque"
}
