# HCL equivalent of this session's manual `helm install` + the Grafana autologin
# `helm upgrade --reuse-values -f ...` - both folded into one helm_release resource here,
# since Terraform tracks the release's values as part of its own state rather than needing a
# separate upgrade step. See variables.tf's enable_monitoring for why this is conditional
# (doesn't fit the project's ~1GB "without monitoring" minimum system requirement).

locals {
  # Same hostname on both targets (the Ingress rule in ingress.tf is identical either way);
  # only the port differs, for the reason documented in k8s/ingress.yaml - k3s's ServiceLB
  # binds Traefik to the node's port 80, while the Helm-installed Traefik on minikube is a
  # NodePort on 30080. Kept next to the helm_release that consumes it rather than in
  # versions.tf, since nothing else needs it.
  grafana_root_url = var.deployment_target == "aws" ? "http://grafana.url-shortener.local/" : "http://grafana.url-shortener.local:30080/"
}

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
      # The Overview dashboard's Run/Stop button reads its own label from
      # kube_job_status_active, which comes from kube-state-metrics - and the trigger service
      # deliberately blocks until Prometheus reports the new value (see
      # loadtest_trigger.tf), so this interval directly sets how long the button's spinner
      # stays up on every click. It otherwise inherits the chart's 30s global default.
      #
      # 1s is aggressive on purpose and is a local-demo tradeoff, not a general
      # recommendation: kube-state-metrics exposes a series per object in the cluster, so this
      # ingests ~30x the samples (and storage) the default would for this one target. It's
      # affordable here because the cluster is tiny and short-lived, and it buys a button that
      # reacts about as fast as the click. The global 30s is deliberately left alone for
      # every other target. scrape_timeout must be <= scrape_interval or Prometheus rejects
      # the config outright, and the ServiceMonitor would otherwise inherit the 10s global.
      "kube-state-metrics" = {
        prometheus = {
          monitor = {
            interval      = "1s"
            scrapeTimeout = "1s"
          }
        }
      }
      grafana = {
        "grafana.ini" = {
          auth = {
            disable_login_form = true
          }
          "auth.anonymous" = {
            enabled  = true
            org_role = "Admin"
          }
          # /tmp/dashboards is where the chart's dashboard-sidecar (grafana-sc-dashboard
          # container, confirmed via its FOLDER env var) actually writes ConfigMap-provisioned
          # dashboards inside the Grafana pod's filesystem - this has to be a real in-pod file
          # path, not a dashboard UID/URL. Only takes effect on Grafana startup (this is a
          # grafana.ini setting, not something the running instance re-reads), which a Helm
          # values change naturally causes; see kubernetes_config_map.dashboard_overview above
          # for the ConfigMap this file comes from.
          dashboards = {
            default_home_dashboard_path = "/tmp/dashboards/url-shortener-overview.json"
            # Grafana clamps any dashboard's refresh to this floor (5s by default), so the
            # Overview dashboard's 1s refresh would silently be ignored - leaving the
            # dashboard as the slowest link now that kube-state-metrics is scraped every 1s.
            # Same local-demo tradeoff as that scrape interval: every open dashboard now
            # re-queries Prometheus once a second.
            min_refresh_interval = "1s"
          }
          # Without this, root_url defaults to http://localhost:3000/ - which is correct for
          # Grafana's own in-pod port but wrong for every way anyone actually reaches it here
          # (through Traefik, on the Ingress hostname). That mismatch is not cosmetic: the
          # Overview dashboard's Canvas button calls a RELATIVE endpoint ("/trigger"), and
          # Grafana resolves relative API endpoints against root_url rather than against the
          # browser's current origin - so with the default it fired at
          # http://localhost:3000/trigger, where nothing is listening, and the click failed
          # with a cross-origin/NetworkError instead of ever reaching the cluster (see
          # INCIDENTS.md). Setting this correctly is also just what Grafana's own docs call
          # for when it sits behind a reverse proxy, which it does here.
          server = {
            root_url = local.grafana_root_url
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
