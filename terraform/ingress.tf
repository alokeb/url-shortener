# HCL translation of k8s/ingress.yaml - see that file for why this is two Ingress objects in
# two namespaces, and why both target the "traefik" IngressClass rather than nginx: k3s (aws.tf)
# ships Traefik as its own built-in ingress controller, so these Ingress objects work
# unmodified on both deployment targets - only bootstrap.tf's helm_release.traefik (which
# installs Traefik on minikube, since it has no built-in equivalent) differs by target, not
# these resources.
#
# Plain typed kubernetes_ingress_v1 resources, not kubectl_manifest - Ingress is a stable
# core-ish API (networking.k8s.io/v1), not a CRD, so there's no chicken-and-egg schema problem
# like monitoring.tf's ServiceMonitor has.

resource "kubernetes_ingress_v1" "app" {
  depends_on = [
    helm_release.traefik,
    null_resource.minikube_cluster,
    null_resource.aws_kubeconfig,
    kubernetes_service.app,
    kubernetes_service.loadtest_trigger,
  ]

  metadata {
    name      = "url-shortener-app"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  spec {
    ingress_class_name = "traefik"

    rule {
      host = "app.url-shortener.local"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.app.metadata[0].name
              port {
                number = 8080
              }
            }
          }
        }
      }
    }

    rule {
      host = "grafana.url-shortener.local"
      http {
        path {
          path      = "/trigger"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.loadtest_trigger.metadata[0].name
              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_ingress_v1" "grafana" {
  count = var.enable_monitoring ? 1 : 0
  depends_on = [
    helm_release.traefik,
    null_resource.minikube_cluster,
    null_resource.aws_kubeconfig,
    helm_release.monitoring,
  ]

  metadata {
    name      = "url-shortener-grafana"
    namespace = "monitoring"
  }

  spec {
    ingress_class_name = "traefik"

    rule {
      host = "grafana.url-shortener.local"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "monitoring-grafana"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
