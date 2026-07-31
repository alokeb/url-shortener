# HCL translation of k8s/postgres.yaml - see that file for the reasoning behind PVC vs no
# PVC (Redis), Deployment vs StatefulSet, and strategy=Recreate. Comments here focus on
# what's different in Terraform's shape, not repeating that reasoning.

resource "kubernetes_persistent_volume_claim" "postgres_data" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "postgres-data"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }

  # PVCs are a good example of Terraform's default "diff means destroy+recreate" behavior
  # being actively wrong for this resource: most PVC fields can't be changed in place at all
  # once bound, so Terraform would otherwise want to delete and recreate it (destroying the
  # actual Postgres data) over something as trivial as a label change. This says "never do
  # that automatically, make me handle it by hand instead."
  lifecycle {
    prevent_destroy = false
  }
}

resource "kubernetes_deployment" "postgres" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        app = "postgres"
      }
    }

    template {
      metadata {
        labels = {
          app = "postgres"
        }
      }

      spec {
        container {
          name  = "postgres"
          image = "postgres:16"

          port {
            container_port = 5432
          }

          env {
            name = "POSTGRES_DB"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db.metadata[0].name
                key  = "DB_NAME"
              }
            }
          }
          env {
            name = "POSTGRES_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db.metadata[0].name
                key  = "DB_USER"
              }
            }
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db.metadata[0].name
                key  = "DB_PASSWORD"
              }
            }
          }

          volume_mount {
            name       = "postgres-data"
            mount_path = "/var/lib/postgresql/data"
          }

          resources {
            requests = {
              cpu    = var.postgres_cpu_request
              memory = var.postgres_memory_request
            }
            limits = {
              cpu    = var.postgres_cpu_limit
              memory = var.postgres_memory_limit
            }
          }
        }

        volume {
          name = "postgres-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.postgres_data.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "postgres" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  spec {
    selector = {
      app = "postgres"
    }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}
