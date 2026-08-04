# HCL equivalent of this session's manual `helm install` + the Grafana autologin
# `helm upgrade --reuse-values -f ...` - both folded into one helm_release resource here,
# since Terraform tracks the release's values as part of its own state rather than needing a
# separate upgrade step. See variables.tf's enable_monitoring for why this is conditional
# (doesn't fit the project's ~1GB "without monitoring" minimum system requirement).

resource "helm_release" "monitoring" {
  count = var.enable_monitoring ? 1 : 0
  depends_on = [
    null_resource.minikube_cluster,
    null_resource.aws_kubeconfig,
  ]

  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true

  # Anonymous admin access, login form disabled - convenient for solo local/learning use,
  # but makes Grafana fully open to anything that can reach it. Fine behind
  # `kubectl port-forward` (never touches the internet); would need revisiting before any
  # more direct exposure (NodePort/Ingress/public LoadBalancer).
  values = [
    yamlencode({
      grafana = {
        "grafana.ini" = {
          auth = {
            disable_login_form = true
          }
          "auth.anonymous" = {
            enabled  = true
            org_role = "Admin"
          }
        }
      }
    })
  ]
}

# ServiceMonitor is a Custom Resource the Prometheus Operator defines (installed by the
# helm_release above) - see versions.tf's comment on why this uses the kubectl provider's
# generic kubectl_manifest instead of a typed hashicorp/kubernetes resource. The
# `release: monitoring` label is not decorative: the chart's Prometheus instance is
# configured with `serviceMonitorSelector: {matchLabels: {release: monitoring}}` by default -
# a ServiceMonitor without this exact label is silently ignored, not an error (this is
# exactly the bug this project hit and fixed earlier - see CLAUDE.md).
resource "kubectl_manifest" "app_service_monitor" {
  count      = var.enable_monitoring ? 1 : 0
  depends_on = [helm_release.monitoring, kubernetes_service.app]

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "url-shortener-app"
      namespace = kubernetes_namespace.url_shortener.metadata[0].name
      labels = {
        release = "monitoring"
      }
    }
    spec = {
      selector = {
        matchLabels = {
          app = "url-shortener-app"
        }
      }
      endpoints = [
        {
          port     = "http"
          path     = "/actuator/prometheus"
          interval = "15s"
        }
      ]
    }
  })
}

# The chart's bundled Grafana runs a sidecar that auto-loads any ConfigMap labeled
# grafana_dashboard = "1" in its own namespace as a dashboard - no Helm values change needed,
# just the label. These two resources read the SAME JSON files as k8s/dashboards-configmap.yaml
# via file() rather than hand-translating the JSON into HCL like everywhere else in terraform/ -
# a deliberate deviation for this one case, since hand-duplicating a large generated JSON blob
# across two files is a sync hazard this project's usual "translate by hand" pattern doesn't
# have to worry about elsewhere (small, human-written YAML).
resource "kubernetes_config_map" "dashboard_overview" {
  count      = var.enable_monitoring ? 1 : 0
  depends_on = [helm_release.monitoring]

  metadata {
    name      = "url-shortener-dashboard-overview"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "url-shortener-overview.json" = file("${path.module}/../k8s/dashboards/url-shortener-overview.json")
  }
}

resource "kubernetes_config_map" "dashboard_detail" {
  count      = var.enable_monitoring ? 1 : 0
  depends_on = [helm_release.monitoring]

  metadata {
    name      = "url-shortener-dashboard-detail"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "url-shortener-detail.json" = file("${path.module}/../k8s/dashboards/url-shortener-detail.json")
  }
}
