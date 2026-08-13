# HCL translation of k8s/loadtest-trigger.yaml - see that file for the reasoning behind the
# narrowly-scoped RBAC (Role, not ClusterRole) and the socat-based "generic image, mounted
# script" trigger.

# Unlike k8s/load-test-job.yaml (applied by hand, on demand, only when someone wants to
# actually run a load test right then - see README's Autoscaling section), this ConfigMap is
# applied unconditionally as part of the normal stack. Reason: the trigger service's
# kubectl apply -f (in loadtest-trigger-scripts' Job manifest, below) references this
# ConfigMap by name - without it always present, the very first click of the dashboard's
# "Run Stress Test" button (before anyone has ever run the load test by hand) would create a
# Job whose Pods fail to mount a ConfigMap volume that doesn't exist yet.
resource "kubernetes_config_map" "load_test_script" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "load-test-script"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  data = {
    "load-test.sh" = <<-EOF
      #!/bin/sh
      set -eu

      BASE_URL="$${BASE_URL:-http://url-shortener-app:8080}"
      DURATION_SECONDS="$${DURATION_SECONDS:-300}"
      CONCURRENCY="$${CONCURRENCY:-40}"

      end=$(( $(date +%s) + DURATION_SECONDS ))

      worker() {
        worker_id="$1"
        request_num=0
        while [ "$(date +%s)" -lt "$end" ]; do
          request_num=$((request_num + 1))
          url="https://loadtest.example/worker-$worker_id/req-$request_num"
          short_code=$(curl -s -X POST "$BASE_URL/api/urls" \
            -H "Content-Type: application/json" \
            -d "{\"url\": \"$url\"}" \
            | sed -n 's/.*"shortCode":"\([^"]*\)".*/\1/p')
          if [ -n "$short_code" ]; then
            curl -s -o /dev/null "$BASE_URL/$short_code"
            curl -s -o /dev/null "$BASE_URL/$short_code"
            curl -s -o /dev/null "$BASE_URL/$short_code"
          fi
        done
        echo "worker $worker_id done: $request_num requests"
      }

      worker_num=1
      while [ "$worker_num" -le "$CONCURRENCY" ]; do
        worker "$worker_num" &
        worker_num=$((worker_num + 1))
      done
      wait
      echo "Load test complete."
    EOF
  }
}

resource "kubernetes_service_account" "loadtest_trigger" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "loadtest-trigger"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }
}

resource "kubernetes_role" "loadtest_trigger" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "loadtest-trigger"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "delete", "get", "list"]
  }

  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "patch"]
  }
}

resource "kubernetes_role_binding" "loadtest_trigger" {
  metadata {
    name      = "loadtest-trigger"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.loadtest_trigger.metadata[0].name
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  role_ref {
    kind      = "Role"
    name      = kubernetes_role.loadtest_trigger.metadata[0].name
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_config_map" "loadtest_trigger_scripts" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "loadtest-trigger-scripts"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  data = {
    "trigger.sh" = <<-EOF
      #!/bin/sh
      set -eu

      # socat's SYSTEM: address wires the accepted connection to this script's stdin/stdout -
      # the request line (e.g. "GET /trigger?min=2&max=10 HTTP/1.1") is the first thing on
      # stdin.
      read -r request_line
      path_and_query=$(printf '%s' "$request_line" | awk '{print $2}')
      query=""
      case "$path_and_query" in
        *\?*) query="$${path_and_query#*\?}" ;;
      esac

      # Drain the rest of the request (headers, up to the blank CRLF line that ends them)
      # before writing any response - if the OS still has unread bytes sitting in this
      # connection's receive buffer when the script exits and socat closes it, it sends a TCP
      # RST instead of a clean FIN. `curl` tolerates that fine (which is why manual curl
      # testing looked like it worked perfectly), but a real browser's fetch() treats a RST as
      # a hard network error and fails the request silently - exactly what was happening to
      # the dashboard's button click.
      while IFS= read -r line; do
        line=$${line%$(printf '\r')}
        [ -z "$line" ] && break
      done

      get_param() {
        printf '%s\n' "$query" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1
      }

      is_positive_int() {
        case "$1" in
          ''|*[!0-9]*) return 1 ;;
          *) return 0 ;;
        esac
      }

      # One endpoint, toggling on whether the Job currently has any active pods - this is the
      # server-side half of the same state the Overview dashboard's button queries
      # (kube_job_status_active) to decide whether to show "Run" or "Stop", so a click always
      # does the opposite of whatever's currently true. `|| true` + the case normalization
      # below both handle "no such Job" (never started, or already deleted) as "0 active".
      ACTIVE=$(kubectl get job load-test -n url-shortener -o jsonpath='{.status.active}' 2>/dev/null || true)
      case "$ACTIVE" in
        ''|*[!0-9]*) ACTIVE=0 ;;
      esac

      # Both branches deliberately block until the change they made is visible in PROMETHEUS -
      # not merely accepted by the API server. That's what keeps the Overview dashboard's
      # button spinner up for the whole wait: Grafana's Canvas button shows a spinner from
      # click until the HTTP response lands (its loading state is wired to the fetch
      # lifecycle, with no way to bind it to query data), and the button's own label is driven
      # by a Prometheus query - so returning any earlier just trades a spinner for a stale
      # label. Waiting on the Job via kubectl alone isn't enough for the same reason: kubectl
      # sees the change immediately, Prometheus only on its next scrape of kube-state-metrics.
      #
      # Each wait is separately bounded (first arg = max seconds) and non-fatal on timeout, so
      # a wedged cluster degrades to "answers anyway, label catches up late" rather than
      # hanging. The limits are low enough that back-to-back worst cases stay under the
      # browser/Grafana fetch timeout.
      wait_for() {
        limit=$1
        shift
        i=0
        while [ "$i" -lt "$limit" ]; do
          "$@" && return 0
          sleep 1
          i=$((i + 1))
        done
        return 1
      }

      job_active() {
        a=$(kubectl get job load-test -n url-shortener -o jsonpath='{.status.active}' 2>/dev/null || true)
        case "$a" in ''|*[!0-9]*) a=0 ;; esac
        [ "$a" -gt 0 ]
      }

      job_gone() {
        ! kubectl get job load-test -n url-shortener >/dev/null 2>&1
      }

      # Exactly the query the dashboard button's own panel runs, so "Prometheus agrees" here
      # means the label is about to render correctly. Cheap sed rather than a JSON parser: the
      # `or on() vector(0)` guarantees exactly one result, so there's only one "value" pair.
      PROM_URL="http://monitoring-kube-prometheus-prometheus.monitoring:9090/api/v1/query"
      PROM_QUERY='kube_job_status_active{namespace="url-shortener",job_name="load-test"} or on() vector(0)'

      prom_value() {
        curl -sf -m 2 -G "$PROM_URL" --data-urlencode "query=$PROM_QUERY" 2>/dev/null \
          | sed -n 's/.*"value":\[[^,]*,"\([0-9.]*\)"\].*/\1/p' | head -n1
      }

      prom_active() { v=$(prom_value); [ -n "$v" ] && [ "$${v%%.*}" -gt 0 ]; }
      prom_idle()   { v=$(prom_value); [ -n "$v" ] && [ "$${v%%.*}" -eq 0 ]; }

      # enable_monitoring=false is a supported configuration (see variables.tf), and there's
      # no Prometheus to wait on in that case - skip rather than burn the full timeout.
      prom_reachable() { [ -n "$(prom_value)" ]; }

      if [ "$ACTIVE" -gt 0 ]; then
        LOG=$(kubectl delete job load-test -n url-shortener --ignore-not-found 2>&1)
        printf '%s\n' "$LOG" 1>&2
        wait_for 15 job_gone || printf 'timed out waiting for job to disappear\n' 1>&2
        if prom_reachable; then
          wait_for 15 prom_idle || printf 'timed out waiting for Prometheus to report idle\n' 1>&2
        fi
        BODY="{\"status\":\"stopped\",\"message\":\"Load test stopped.\"}"
      else
        MIN_RAW=$(get_param min)
        MAX_RAW=$(get_param max)

        if is_positive_int "$MIN_RAW" && [ "$MIN_RAW" -ge 1 ]; then MIN="$MIN_RAW"; else MIN=1; fi
        if is_positive_int "$MAX_RAW" && [ "$MAX_RAW" -ge 1 ]; then MAX="$MAX_RAW"; else MAX=3; fi

        # 30 matches the ceiling this project already tested up to (see k8s/hpa.yaml's
        # host-stress-test history) - a sanity cap, not a hard Kubernetes limit. min is never
        # allowed above max, so a mistyped value can't wedge the HPA in an impossible state.
        [ "$MAX" -gt 30 ] && MAX=30
        [ "$MIN" -gt "$MAX" ] && MIN="$MAX"

        # One load-generator Job pod (40 concurrent curl workers each, see load-test-script's
        # CONCURRENCY) roughly per target replica - a simple heuristic, not an exact CPU
        # model, but enough sustained aggregate load that the HPA has a real reason to scale
        # all the way to MAX instead of plateauing well below it.
        PARALLELISM="$MAX"

        JOB_YAML="apiVersion: batch/v1
      kind: Job
      metadata:
        name: load-test
        namespace: url-shortener
      spec:
        backoffLimit: 0
        parallelism: $PARALLELISM
        completions: $PARALLELISM
        template:
          spec:
            restartPolicy: Never
            containers:
              - name: load-test
                image: curlimages/curl:8.11.0
                command: [\"sh\", \"/scripts/load-test.sh\"]
                env:
                  - name: DURATION_SECONDS
                    value: \"600\"
                  - name: CONCURRENCY
                    value: \"40\"
                volumeMounts:
                  - name: script
                    mountPath: /scripts
                resources:
                  requests:
                    cpu: 200m
                    memory: 100Mi
                  limits:
                    cpu: 500m
                    memory: 256Mi
            volumes:
              - name: script
                configMap:
                  name: load-test-script"

        LOG=$(
          kubectl patch hpa url-shortener-app -n url-shortener --type=merge \
            -p "{\"spec\":{\"minReplicas\":$MIN,\"maxReplicas\":$MAX}}" 2>&1
          kubectl delete job load-test -n url-shortener --ignore-not-found 2>&1
          printf '%s\n' "$JOB_YAML" | kubectl apply -n url-shortener -f - 2>&1
        )

        printf '%s\n' "$LOG" 1>&2
        wait_for 15 job_active || printf 'timed out waiting for load-test pods to start\n' 1>&2
        if prom_reachable; then
          wait_for 15 prom_active || printf 'timed out waiting for Prometheus to report active\n' 1>&2
        fi
        BODY="{\"status\":\"started\",\"minReplicas\":$MIN,\"maxReplicas\":$MAX,\"loadGeneratorPods\":$PARALLELISM,\"message\":\"Load test started: HPA min=$MIN max=$MAX, $PARALLELISM load-generator pod(s).\"}"
      fi

      # JSON, not text/plain, and deliberately so: the Overview dashboard's Canvas button calls
      # this through Grafana's own backendSrv.fetch(), which parses every response body as JSON
      # and surfaces a parse failure as a generic "An error has occurred" toast - a 200 with a
      # human-readable sentence in it still counts as a failed call from the button's point of
      # view (confirmed by reading Grafana's compiled canvas panel code; see INCIDENTS.md).
      # kubectl's own output goes to stderr instead, which socat leaves attached to the
      # container's logs rather than the client socket - so `kubectl logs deploy/loadtest-trigger`
      # still shows exactly what was applied, without corrupting the JSON body.
      printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: %s\r\n\r\n%s' "$${#BODY}" "$BODY"
    EOF
  }
}

resource "kubernetes_deployment" "loadtest_trigger" {
  depends_on = [kubernetes_namespace.url_shortener]

  metadata {
    name      = "loadtest-trigger"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "loadtest-trigger"
      }
    }

    template {
      metadata {
        labels = {
          app = "loadtest-trigger"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.loadtest_trigger.metadata[0].name

        container {
          name  = "trigger"
          image = "alpine/k8s:1.31.1"
          command = [
            "sh", "-c",
            "apk add --no-cache socat >/tmp/apk.log 2>&1 && exec socat TCP-LISTEN:8080,fork,reuseaddr SYSTEM:\"sh /scripts/trigger.sh\""
          ]

          port {
            container_port = 8080
          }

          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
        }

        volume {
          name = "scripts"
          config_map {
            name = kubernetes_config_map.loadtest_trigger_scripts.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "loadtest_trigger" {
  metadata {
    name      = "loadtest-trigger"
    namespace = kubernetes_namespace.url_shortener.metadata[0].name
  }

  spec {
    selector = {
      app = "loadtest-trigger"
    }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}
