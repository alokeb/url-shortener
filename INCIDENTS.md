# Incident log

This is the "reviewable operational history" for this project — a compact decision record
for each real mistake made while building it, instead of leaving a future reader (human or
agent) to reverse-engineer the reasoning from a diff. Each entry follows the same shape:

- **Triggering signal** — what showed something was wrong
- **Rejected fix** — the assumption or approach that turned out not to work
- **Tested remedy** — what actually fixed it, and how that was confirmed
- **Why accepted** — the reasoning that made this the right fix, not just *a* fix

These are folded into the commit that shipped the working version rather than split across a
broken commit and a fix commit — so each entry below links to the single commit where the
fix already landed, and to the code comment where the reasoning is preserved long-term.

---

## 1. Fresh-rollout crash loop (no readiness ordering between Deployments)

- **Triggering signal:** On the very first `kubectl apply`, the app Pod crash-looped
  repeatedly instead of coming up clean.
- **Rejected fix:** Assuming Kubernetes would sequence the app after Postgres the way
  Docker Compose's `depends_on` does. It doesn't — plain Deployments have no ordering
  guarantee between each other at all, so the app's Pod could (and did) start before
  Postgres's Pod was accepting connections.
- **Tested remedy:** Added a `wait-for-postgres` initContainer (`busybox`, running
  `until nc -z postgres 5432; do sleep 2; done`) ahead of the app container.
- **Why accepted:** initContainers run to completion before any container in `containers:`
  is even created — this blocks on actual readiness (a real TCP accept), not just on
  Postgres's process having started. `busybox` was picked purely because it's small and has
  `nc`; nothing else about the check needed a bigger image.
- **Where:** [`k8s/app.yaml`](k8s/app.yaml) (`initContainers:` block) — commit
  [`aefdd9d`](https://github.com/alokeb/url-shortener/commit/aefdd9d) *Add app Deployment and Service manifests*.

## 2. Prometheus silently had no target for the app

- **Triggering signal:** `/actuator/prometheus` was live and reachable, but nothing was
  showing up as a scrape target in Prometheus — no error surfaced anywhere; it just wasn't
  there.
- **Rejected fix:** Assuming a `ServiceMonitor` pointing at the app's `Service` would be
  enough on its own to get it scraped.
- **Tested remedy:** Ran `kubectl get prometheus -n monitoring -o jsonpath=...` and found the
  chart's Prometheus instance is configured with
  `serviceMonitorSelector: {matchLabels: {release: monitoring}}`. Added the `release:
  monitoring` label to the `ServiceMonitor` itself, *and* added a separate `app:
  url-shortener-app` label directly on the `Service` object's `metadata.labels` (distinct
  from the Service's own `spec.selector`, which is a different thing entirely) for the
  `ServiceMonitor`'s `selector.matchLabels` to match against.
- **Why accepted:** This is kube-prometheus-stack's actual label contract, not a workaround —
  a `ServiceMonitor` missing that exact label is a silent no-op by design, which is exactly
  why the gap didn't throw an error and had to be found by checking the Prometheus CRD's
  config directly.
- **Where:** [`k8s/servicemonitor.yaml`](k8s/servicemonitor.yaml) and the `Service` block in
  [`k8s/app.yaml`](k8s/app.yaml) — commit
  [`653c94e`](https://github.com/alokeb/url-shortener/commit/653c94e) *Add ServiceMonitor so Prometheus scrapes the app*.
  Reapplied in Terraform at [`terraform/monitoring.tf`](terraform/monitoring.tf).

## 3. Memory limit too low for the JVM's real footprint

- **Triggering signal:** With Terraform's `app_memory_limit` set to `256Mi`, the app
  container crash-looped — kubelet was killing and restarting it on failed liveness checks.
- **Rejected fix:** `256Mi` was the original guess, sized to fit the project's stated ~1GB
  "without monitoring" minimum system requirement across Postgres + Redis + app.
- **Tested remedy:** Measured the app's actual resting JVM footprint (Tomcat + Hibernate +
  Spring context) directly and found it sits around 300–400Mi at idle — already above the
  256Mi limit before any request load. Raised `app_memory_limit` to `450Mi` (and
  `app_memory_request` to `350Mi`).
- **Why accepted:** 256Mi wasn't a tight-but-workable constraint, it was below the JVM's real
  floor — the JVM spent its time fighting GC to stay under an unreachable limit, which is
  what made health-check responses slow enough to fail liveness probes. 450Mi leaves real
  headroom above the observed baseline; the ~1GB total budget stays genuinely tight with
  Postgres + Redis running too (expected, not a bug), and it still holds because Kubernetes
  schedules against *requests*, not *limits*.
- **Where:** [`terraform/variables.tf`](terraform/variables.tf) — commit
  [`4815e2c`](https://github.com/alokeb/url-shortener/commit/4815e2c) *Add Terraform variables for sizing, credentials, and
  deployment target*.
