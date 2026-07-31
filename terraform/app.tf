# HCL translation of k8s/app.yaml + k8s/hpa.yaml. See those files for the reasoning behind
# the initContainer (no depends_on-equivalent between Deployments in plain Kubernetes), the
# Service's own labels (what the ServiceMonitor in monitoring.tf actually matches against),
# and the specific resource request/limit numbers (sized for the host-stress-test phase).

resource "kubernetes_deployment" "app" {
  depends_on = [
    kubernetes_namespace.url_shortener,
    null_resource.app_image_load_local,
    null_resource.app_image_load_aws,
  ]

  metadata {
    name      = "url-shortener-app"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "url-shortener-app"
      }
    }

    template {
      metadata {
        labels = {
          app = "url-shortener-app"
        }
      }

      spec {
        init_container {
          name    = "wait-for-postgres"
          image   = "busybox:1.36"
          command = ["sh", "-c", "until nc -z postgres 5432; do echo waiting for postgres...; sleep 2; done"]
        }

        container {
          name  = "app"
          image = "url-shortener-app:latest"
          # See bootstrap.tf's null_resource.app_image - this image only exists inside
          # minikube because it was loaded there directly, there's no registry to pull from.
          image_pull_policy = "Never"

          port {
            container_port = 8080
          }

          env {
            name  = "DB_HOST"
            value = "postgres"
          }
          env {
            name  = "DB_PORT"
            value = "5432"
          }
          env {
            name  = "REDIS_HOST"
            value = "redis"
          }
          env {
            name  = "REDIS_PORT"
            value = "6379"
          }
          env {
            name = "DB_NAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db.metadata[0].name
                key  = "DB_NAME"
              }
            }
          }
          env {
            name = "DB_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db.metadata[0].name
                key  = "DB_USER"
              }
            }
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.db.metadata[0].name
                key  = "DB_PASSWORD"
              }
            }
          }

          resources {
            requests = {
              cpu    = var.app_cpu_request
              memory = var.app_memory_request
            }
            limits = {
              cpu    = var.app_cpu_limit
              memory = var.app_memory_limit
            }
          }

          liveness_probe {
            http_get {
              path = "/actuator/health"
              port = 8080
            }
            initial_delay_seconds = 20
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/actuator/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "app" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "url-shortener-app"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
    # Not decorative - see monitoring.tf's ServiceMonitor selector, which matches THIS
    # label on the Service object itself (not the Pods). Missing this was a real bug hit
    # earlier in this project when the equivalent YAML Service had no labels at all.
    labels = {
      app = "url-shortener-app"
    }
  }

  spec {
    selector = {
      app = "url-shortener-app"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "app" {
  depends_on = [kubernetes_deployment.app]

  metadata {
    name      = "url-shortener-app"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.app.metadata[0].name
    }

    min_replicas = var.app_min_replicas
    max_replicas = var.app_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.app_cpu_target_percent
        }
      }
    }
  }
}
