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

## 4. Redis cache metrics never appeared

- **Triggering signal:** `/actuator/prometheus` had zero `cache_*` metrics after real
  traffic — no `cache_gets_total`, nothing — despite `@Cacheable("shortUrls")` visibly working
  (Redis GET/SET calls showing up in the app's own `lettuce_*` metrics).
- **Rejected fix:** Assuming Micrometer's cache-metrics binder just needed cache traffic to
  exist. It didn't: two separate gaps stacked on top of each other. First, Redis cache
  statistics collection is off by default (`spring.cache.redis.enable-statistics`). Second,
  even with that on, Spring Boot's cache-metrics registrar only scans for caches to bind
  **once, at application startup** — `RedisCacheManager` creates caches lazily on first use, so
  an un-pre-declared cache name doesn't exist yet at that scan and never gets metrics bound
  afterward, no matter how much traffic follows.
- **Tested remedy:** Set both `spring.cache.redis.enable-statistics=true` and
  `spring.cache.cache-names=shortUrls` (pre-declaring the name so it exists before the
  startup-time scan runs). Verified live: after 1 POST + 5 GETs,
  `cache_gets_total{result="hit"}=4`, `result="miss"=1`, `cache_puts_total=1` — exactly
  matching the real hit/miss pattern.
- **Why accepted:** Both properties are the documented, supported mechanism (confirmed by
  reading Spring Boot 4.1's actual `RedisCacheConfiguration`/`CacheMetricsRegistrarConfiguration`
  source, not guessed) — this isn't a workaround, it's turning on a feature that ships off by
  default and satisfying an ordering requirement the framework doesn't warn you about.
- **Where:** [`src/main/resources/application.properties`](src/main/resources/application.properties) — commit
  [`18c82db`](https://github.com/alokeb/url-shortener/commit/18c82db) *Enable Redis cache statistics and fix Micrometer binding*.

## 5. Traefik Helm install silently ignored its own values override

- **Triggering signal:** `terraform apply` failed with `context deadline exceeded` on
  `helm_release.traefik` after a 5-minute hang, and `helm status` showed the release itself as
  `failed` even though the Deployment/Pod had come up fine.
- **Rejected fix:** Setting `service.type = "NodePort"` in the Helm values (to avoid needing
  the LoadBalancer external IP minikube never provides). This key doesn't error when it's
  wrong — Helm just silently keeps the chart's default (`LoadBalancer`) instead, and
  Terraform's `helm_release` resource waits for that Service to become ready by default, which
  for a `LoadBalancer` on minikube means waiting forever for an external IP that's never
  coming.
- **Tested remedy:** Ran `helm show values traefik/traefik` against the real chart and found
  the actual key is nested one level deeper: `service.spec.type`, not `service.type`. Fixed
  the override; the same `terraform apply` that had hung for 5 minutes completed in 5 seconds.
- **Why accepted:** Confirmed against the chart's own schema rather than guessed a second
  time — this specific chart nests Service overrides under `service.spec` (to allow arbitrary
  additional ServiceSpec fields), which isn't the convention every chart uses, so there was no
  way to know without checking.
- **Where:** [`terraform/bootstrap.tf`](terraform/bootstrap.tf) (`helm_release.traefik`) — commit
  [`c9d68bb`](https://github.com/alokeb/url-shortener/commit/c9d68bb) *Add custom Grafana dashboards, stress-test trigger, and
  Traefik Ingress*.

## 6. Stress-test trigger's HPA patch failed with 403 Forbidden

- **Triggering signal:** Clicking the dashboard's "Run Stress Test" button correctly scaled
  and created the load-test Job, but the response body included
  `Error from server (Forbidden): horizontalpodautoscalers.autoscaling "url-shortener-app" is
  forbidden` for the `kubectl patch hpa` call.
- **Rejected fix:** None needed to reject — this was a straightforward gap, not a wrong
  assumption: the trigger service's RBAC `Role` was written (and tested) before the min/max
  replica feature added a second kind of action (`kubectl patch hpa`) to the same script, and
  the `Role`'s rules were never updated to match. Caught immediately by actually exercising
  the button end-to-end against a live cluster rather than trusting that `terraform validate`
  passing meant the RBAC was sufficient (it only checks HCL syntax, not what the workload
  inside a container actually needs at runtime).
- **Tested remedy:** Added a second `rule` to the `Role` granting `get`/`patch` on
  `horizontalpodautoscalers` in the `autoscaling` API group, scoped to this one namespace only
  (same as the existing Job permissions). Re-tested: HPA patch and Job creation both succeeded.
- **Why accepted:** Least-privilege still holds — the added permissions are exactly the two
  verbs the script calls (`get` isn't strictly required for a merge-patch but keeping it
  matches `kubectl`'s own preflight behavior), on exactly the one HPA object this service is
  meant to touch, nothing cluster-wide.
- **Where:** [`k8s/loadtest-trigger.yaml`](k8s/loadtest-trigger.yaml) (`Role` rules) — commit
  [`c9d68bb`](https://github.com/alokeb/url-shortener/commit/c9d68bb) *Add custom Grafana dashboards, stress-test trigger, and
  Traefik Ingress*.

## 7. Stress-test button worked from curl, not from a real browser

- **Triggering signal:** The Run/Stop button worked once, then stopped responding to clicks -
  no visible error, no state change. Manual `curl` testing of the exact same endpoint,
  including with a full set of browser-like headers (`Origin`, `Sec-Fetch-*`, a real
  `User-Agent`), succeeded every time. The gap only showed up from an actual browser.
- **Rejected fix (round 1):** Assumed Grafana's newer "Actions" feature (fires a request via
  `fetch()`, no navigation) just needed the right JSON under a separate
  `fieldConfig.defaults.actions` array. Confirmed via `helm show values`-style inspection of
  Grafana's own compiled frontend bundle that the actual property names existed
  (`title`/`confirmation`/`oneClick`/`fetch: {method,url,...}`) - but adding it alongside the
  working data link changed nothing, and removing the data link entirely made the button fully
  unclickable. Root cause: further bundle inspection showed the combined "link or action" list
  a Stat panel actually reads from is the existing `links` array itself, with a `type: "fetch"`
  discriminator on individual entries (`"type" in item ? item[item.type].url : item.url`) -
  not a separate sibling array at all.
- **Rejected fix (round 2):** Rebuilt the button as a single `links` entry with the correct
  `type: "fetch"` discriminator, confirmed stored correctly via Grafana's dashboard API. Click
  still silently did nothing. Along the way, found and fixed two real, independent bugs that
  were never the actual root cause but are worth keeping regardless: the trigger script never
  drained the incoming request before writing its response, which leaves unread bytes in the
  socket's receive buffer at close time - the OS sends a TCP RST instead of a clean FIN, which
  `curl` tolerates silently but a real `fetch()` treats as a hard network error (explains why
  curl testing never caught this); and the response had no `Cache-Control` header, incorrect
  for a state-changing GET regardless of whether it explained the symptom.
- **Tested remedy:** With both real bugs fixed and the schema confirmed structurally correct
  against Grafana's own compiled code, checked the browser's Network tab directly (the one
  piece of ground truth no amount of server-side testing or bundle reading could substitute
  for) after several clicks: zero requests to `/trigger` at all. Reverted the button to a plain
  `links` entry (`type` omitted, `targetBlank: true`) - the mechanism already confirmed working
  end-to-end earlier in the same session.
- **Why accepted:** Two rounds of reverse-engineering Grafana's own compiled frontend code
  (not guessing from memory) both produced schemas that were stored correctly but never
  actually fired a request from a real Stat panel click in the deployed Grafana version
  (13.1.1) - strong evidence this specific Action mechanism is Canvas-panel-specific (or
  otherwise unsupported here) rather than a general Stat-panel capability, despite the field
  names existing generically in the bundle. A working new-tab click beats a broken same-tab
  one; noted as an open roadmap item rather than pursued further blind.
- **Where:** [`k8s/dashboards/url-shortener-overview.json`](k8s/dashboards/url-shortener-overview.json) (button panel),
  [`k8s/loadtest-trigger.yaml`](k8s/loadtest-trigger.yaml) (`trigger.sh` drain + `Cache-Control`) — commit
  [`ca87bd0`](https://github.com/alokeb/url-shortener/commit/ca87bd0) *Add stress-test Run/Stop toggle, min/max replica
  controls, and Grafana home dashboard*.
