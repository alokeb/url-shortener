# HCL translation of k8s/redis.yaml - no PVC, same reasoning as that file: pure cache, not
# a source of truth.

resource "kubernetes_deployment" "redis" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "redis"
      }
    }

    template {
      metadata {
        labels = {
          app = "redis"
        }
      }

      spec {
        container {
          name  = "redis"
          image = "redis:7"

          port {
            container_port = 6379
          }

          resources {
            requests = {
              cpu    = var.redis_cpu_request
              memory = var.redis_memory_request
            }
            limits = {
              cpu    = var.redis_cpu_limit
              memory = var.redis_memory_limit
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  spec {
    selector = {
      app = "redis"
    }
    port {
      port        = 6379
      target_port = 6379
    }
  }
}
