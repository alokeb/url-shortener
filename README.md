# url-shortener

[![License: MIT](https://img.shields.io/github/license/alokeb/url-shortener)](LICENSE)
![Java](https://img.shields.io/badge/Java-21-orange)
![Spring Boot](https://img.shields.io/badge/Spring%20Boot-4.1.0-brightgreen)
![Kubernetes](https://img.shields.io/badge/Kubernetes-ready-326CE5?logo=kubernetes&logoColor=white)
![Terraform](https://img.shields.io/badge/Terraform-IaC-844FBA?logo=terraform&logoColor=white)

A URL shortening service — and, more importantly, a real example of what "vibe coding" (building real software by working with an AI coding agent) actually looks like past the first five minutes.

Most AI-pair-programming demos stop at a toy CRUD app. This one didn't: it started the same way — a Spring Boot service, Postgres, Redis — and then kept going the way a real project does. Containerizing it. Deploying it to Kubernetes. Wiring up autoscaling and a Prometheus/Grafana monitoring stack. Actually stress-testing it. Automating the whole deployment with Terraform. Every step — including the mistakes (a race condition that crash-looped a pod, a monitoring config that was silently ignored, a memory limit that turned out to be too small) — is in the commit history and in [`CLAUDE.md`](CLAUDE.md), not cleaned up after the fact. Each of those mistakes is also written up as a compact decision record — trigger, rejected fix, tested remedy, and why — in [`INCIDENTS.md`](INCIDENTS.md).

If you're newer to coding and curious what working with an AI agent on something real actually involves — not a one-shot snippet, but an evolving codebase with real infrastructure decisions — this repo is meant to be read, not just run. Clone it, open the commit history, see how one small project grew.

⭐ If this is useful to you as a learning example, a star helps other people find it too.

**Development approach:** every commit in this repository was written in close collaboration with [Claude](https://claude.com) (Anthropic's AI), acting as a pairing partner on architecture, implementation, debugging, and infrastructure decisions throughout. That collaboration used to be recorded per-commit via a `Co-Authored-By` trailer; it's now disclosed here instead, once for the whole project, so it's easier to read as a narrative and doesn't crowd out the commit log.

## What it does

Given a long URL, it generates a short code (or reuses the one it already gave that URL — shortened URLs are permalinks) and redirects to the original URL when that code is visited.

What started as a local Docker Compose app has grown into a full Kubernetes deployment with autoscaling and a Prometheus/Grafana monitoring stack, deployable either locally (minikube) or to a small AWS instance — all through Terraform.

## Stack

- Java 21, Spring Boot 4.1.0 (Web MVC, Spring Data JPA, Validation, Cache, Actuator)
- PostgreSQL — persistent storage, the source of truth
- Redis — caches short-code lookups so repeated redirects don't hit Postgres every time
- Docker / Docker Compose — local build/run/orchestration
- Kubernetes — Deployments, Services, a HorizontalPodAutoscaler, a Traefik Ingress, all in `k8s/`
- Helm — installs the monitoring stack (Prometheus + Grafana + Alertmanager) and, on minikube, Traefik itself
- Terraform — one-command deploy of everything above, to either a local minikube cluster or an AWS EC2 instance running k3s
- Testcontainers — spins up real, throwaway Postgres/Redis containers for the test suite

## Project layout

```
src/main/java/com/alokeb/urlshortener/
├── UrlShortenerApplication.java   # entry point, @EnableCaching
├── model/UrlMapping.java          # JPA entity: id, shortCode, originalUrl, createdAt
├── repository/UrlMappingRepository.java  # Spring Data derived queries
├── service/UrlShortenerService.java      # dedupe + host-case normalization on shorten(),
│                                          # Redis-backed @Cacheable on resolve()
└── web/
    ├── UrlShortenerController.java   # REST endpoints
    ├── ShortenRequest.java           # POST request body
    └── ShortenResponse.java          # POST response body

src/main/resources/
├── application.properties   # env-var-driven Postgres/Redis config, /actuator/prometheus
└── static/tester.html       # simple browser form to shorten/test URLs

src/test/java/com/alokeb/urlshortener/
├── UrlShortenerApplicationTests.java      # plain context-load smoke test
└── service/UrlShortenerServiceStressTest.java  # see Testing below

Dockerfile           # multi-stage build (Maven -> slim JRE runtime)
docker-compose.yml   # app + postgres + redis, local dev only (see below)
.env.example          # copy to .env and fill in real values (.env is git-ignored)
requests.http          # REST Client (VS Code) requests for shorten + redirect
test-requests.sh        # zero-dependency curl script exercising the same flow

k8s/                 # plain kubectl manifests - namespace, Secret, Postgres, Redis, app, HPA,
│                     # ServiceMonitor, a load-test Job, a Grafana dashboard ConfigMap pair,
│                     # the load-test trigger service, and the Traefik Ingress
└── ...

terraform/            # deploys everything in k8s/ (plus the Helm monitoring stack) with
│                      # one command, to either local minikube or AWS - see "Deploying" below
├── credentials.tfvars.example   # copy to credentials.auto.tfvars, fill in AWS keys
├── terraform.tfvars.example     # copy to terraform.tfvars to override any default
└── ...
```

## Prerequisites

Every tool below is cross-platform (Linux/macOS/Windows) — install whichever your OS's package manager or the linked installer prefers. You only need the ones for the path you're actually using (see the table under "Deploying").

| Tool | Get it |
|---|---|
| Docker | https://docs.docker.com/get-docker/ |
| kubectl | https://kubernetes.io/docs/tasks/tools/#kubectl |
| minikube | https://minikube.sigs.k8s.io/docs/start/ |
| Helm | https://helm.sh/docs/intro/install/ |
| Terraform | https://developer.hashicorp.com/terraform/install |
| conntrack (Linux only, needed by minikube's Docker driver) | usually available via your Linux distro's own package manager (e.g. `conntrack` on Debian/Ubuntu, `conntrack-tools` on Fedora/Arch) |

No local JDK or Maven needed for any path — the app is always built inside Docker.

## Deploying

Three ways to run this, from simplest to most complete:

| Path | What you get | Needs |
|---|---|---|
| **Docker Compose** | app + Postgres + Redis, no Kubernetes | Docker |
| **Local Kubernetes** | + autoscaling, monitoring dashboard | + kubectl, minikube, Helm (or Terraform to automate it) |
| **AWS** (example cloud target) | same as local K8s, but on a real internet-reachable server | + Terraform, an AWS account |

### Option 1: Docker Compose (simplest)

```bash
cp .env.example .env   # first time only; edit in a real password
docker compose up -d --build
```

Starts three containers: `app` (port `8080`), `postgres`, `redis`. Postgres/Redis also publish to `127.0.0.1` only (reachable from local tooling on this machine, never from the network).

**Teardown:** `docker compose down` (add `-v` to also wipe the Postgres volume).

If something's misbehaving after editing `docker-compose.yml` and a restart doesn't fix it, try `docker compose up -d --force-recreate` — a plain restart can leave stale network state behind when config changed but the image didn't.

### Option 2: Local Kubernetes (minikube)

Either apply the plain manifests by hand, or let Terraform do the whole thing (cluster included):

**By hand:**
```bash
minikube start --driver=docker --memory=20000
minikube addons enable metrics-server
docker build -t url-shortener-app:latest .
minikube image load url-shortener-app:latest
kubectl apply -f k8s/namespace.yaml -f k8s/secret.yaml -f k8s/postgres.yaml \
  -f k8s/redis.yaml -f k8s/app.yaml -f k8s/hpa.yaml -f k8s/servicemonitor.yaml \
  -f k8s/loadtest-trigger.yaml
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
kubectl apply -f k8s/dashboards-configmap.yaml
# minikube has no built-in Traefik addon (unlike its nginx one) - see k8s/ingress.yaml's
# comment for why Traefik specifically, and why the port numbers below.
helm install traefik traefik/traefik -n kube-system \
  --set ingressClass.enabled=true --set ingressClass.name=traefik \
  --set service.type=NodePort --set ports.web.nodePort=30080 --set ports.websecure.nodePort=30443
kubectl apply -f k8s/ingress.yaml
```

Note: `k8s/loadtest-trigger.yaml` depends on the `load-test-script` ConfigMap that `k8s/load-test-job.yaml` creates (see Autoscaling below) - applying that file at least once, by hand or via the trigger button, is needed before the trigger actually works. The Terraform path doesn't have this gap (`terraform/loadtest_trigger.tf` applies that ConfigMap unconditionally, up front).

**Or via Terraform** (see "Terraform" below for the full explanation) — from `terraform/`:
```bash
terraform init
terraform apply -target=null_resource.minikube_cluster -auto-approve   # phase 1: cluster only
terraform apply -auto-approve                                          # phase 2: everything else
```

**Teardown:**
```bash
kubectl delete namespace url-shortener monitoring   # if deployed by hand
# or, if deployed via terraform:
terraform destroy -auto-approve
minikube stop     # or `minikube delete` to remove the cluster entirely
```

### Option 3: AWS (example cloud target)

Everything in `k8s/` (Postgres, Redis, the app, the HPA, monitoring) only ever talks to "a Kubernetes cluster" — it has no idea whether that cluster is minikube or a cloud VM. AWS is provided as the one concrete, tested-locally reference implementation of "provision a cloud cluster for this," via `terraform/aws.tf`: it provisions a single EC2 instance running [k3s](https://k3s.io/) (a lightweight, fully real Kubernetes distribution), then deploys the same app/Postgres/Redis/HPA into it. Adding another cloud provider later is a matter of writing one more file following that same shape (VM + firewall + SSH keypair + k3s install script + kubeconfig fetch) — see `aws.tf`'s own comments for the pattern.

**Minimum system requirements** (this instance, or any machine running this stack): ~1 vCPU / ~1GB RAM without monitoring, ~2 vCPU / ~3GB RAM with it enabled. `aws_instance_type` (`terraform/variables.tf`) defaults to `t3.micro`, which meets the smaller tier and happens to also be AWS's free-tier-eligible size — a bonus, not the reason it was chosen. Any instance type meeting the requirement above works. **Note:** AWS's managed Kubernetes service (EKS) has no free tier at all (a flat ~$73/month for the control plane alone regardless of usage) — this deliberately runs k3s on a plain EC2 instance instead, specifically to avoid that. A card on file is still required by AWS even for free-tier usage, and leaving resources running past whatever limits apply to your account, or forgetting to tear down, will incur real charges.

**This path is written carefully but has not been live-tested against a real AWS account** (no credentials were available to verify it end-to-end while building it) — unlike the local minikube path, which was fully applied and destroyed successfully. Run `terraform plan` first (read-only, safe, costs nothing) to review what it would do before your first real `apply`, and keep an eye on the AWS Console while it runs the first time.

```bash
cd terraform
cp credentials.tfvars.example credentials.auto.tfvars   # fill in real AWS keys
cp terraform.tfvars.example terraform.tfvars             # uncomment deployment_target = "aws"

terraform init
terraform apply -target=null_resource.aws_kubeconfig -auto-approve   # phase 1: provision EC2 + k3s
terraform apply -auto-approve                                        # phase 2: everything else
```

`enable_monitoring` defaults to `true`, which needs the larger (~2 vCPU/~3GB) tier above — set `enable_monitoring = false` in `terraform.tfvars` if you're using an instance sized only to the smaller (~1 vCPU/~1GB) minimum, like the default `t3.micro`.

**Teardown:** `terraform destroy -auto-approve` — this deletes the EC2 instance and everything on it. Always run this when you're done to avoid ongoing charges.

### Terraform: why two `apply` commands?

Terraform's provider configuration (the `kubernetes`/`helm`/`kubectl` blocks) has to be resolved *before* Terraform knows what resources exist — so it can't wait for a not-yet-created cluster the way individual resources can wait on each other. The first `apply` (targeted at just the cluster-bootstrap resource) exists purely to get a live cluster and valid kubeconfig in place; the second `apply` does everything else now that the provider blocks can actually connect. This is a real, documented Terraform limitation, not a workaround for a mistake in this config.

After that first cluster exists, subsequent `terraform apply` runs (e.g. after a code change) only need the single, normal command — the two-phase dance is only needed when the cluster itself doesn't exist yet.

### Ingress: accessing without port-forward

An Ingress (`k8s/ingress.yaml` / `terraform/ingress.tf`) routes both the app and Grafana by hostname, so neither needs its own `kubectl port-forward` running. It targets Traefik specifically (not the more common ingress-nginx) because k3s — the AWS path's cluster — already ships Traefik built in; writing against it means the same Ingress objects work unmodified on both deployment targets. minikube has no equivalent built-in Traefik, so the local path installs it via Helm (`terraform/bootstrap.tf`'s `helm_release.traefik`, or the manual `helm install traefik ...` step above for the by-hand path).

One-time step either way: point both hostnames at the right IP. Terraform can't portably edit `/etc/hosts` for you (OS-specific, needs elevated permissions), so this stays manual:

```bash
# Local (minikube):
echo "$(minikube ip) app.url-shortener.local grafana.url-shortener.local" | sudo tee -a /etc/hosts

# AWS (see "terraform output" for the instance's public IP):
echo "<EC2 instance public IP> app.url-shortener.local grafana.url-shortener.local" | sudo tee -a /etc/hosts
```

Then:

| | Local (minikube) | AWS |
|---|---|---|
| App / tester page | `http://app.url-shortener.local:30080/tester.html` | `http://app.url-shortener.local/tester.html` |
| Grafana | `http://grafana.url-shortener.local:30080` | `http://grafana.url-shortener.local` |

The port difference is a real infrastructure difference, not an inconsistency: k3s's built-in ServiceLB binds Traefik straight to the node's port 80/443 (designed for exactly this bare-node case, no cloud load balancer needed), while the Helm-installed Traefik on minikube uses a NodePort instead of a LoadBalancer Service, since minikube's Docker driver never assigns a LoadBalancer Service a real external IP without a separate, permanently-running `minikube tunnel` process.

### Accessing things once deployed (either Kubernetes path)

The Ingress above is the primary way to reach things now. `kubectl port-forward` still works as a fallback (e.g. if you haven't set up the `/etc/hosts` entries, or Ingress isn't deployed):

```bash
kubectl port-forward -n url-shortener svc/url-shortener-app 8080:8080   # app: http://localhost:8080
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80       # Grafana: http://localhost:3000 (auto-logged in as admin)
```

For the AWS path, run `export KUBECONFIG=terraform/generated/aws-kubeconfig` first so `kubectl` points at the right cluster (`terraform output` prints this reminder too).

## API

### Shorten a URL

```bash
curl -X POST http://localhost:8080/api/urls \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com/some/very/long/path"}'
```

Response:

```json
{"shortCode": "7Sgvani", "shortUrl": "http://localhost:8080/7Sgvani"}
```

`url` must start with `http://` or `https://`. Shortening the same URL again returns the *same* short code instead of minting a new one — matching is exact except the host is treated case-insensitively (`Example.com` and `example.com` dedupe to the same code; the path does not, since paths are case-sensitive by spec).

### Follow a short code

```bash
curl -i http://localhost:8080/7Sgvani
```

Returns a `302` redirect to the original URL (or `404` if the code doesn't exist).

### Browser tester

With the stack running, open `http://localhost:8080/tester.html` for a simple form to shorten URLs and click through the results. It has to be loaded through the running app at that URL (not opened as a local file) — its JavaScript calls the API using a relative path, which only resolves correctly when served by the app itself.

### Other ways to poke at the API

- `requests.http` — open in VS Code with the [REST Client](https://marketplace.visualstudio.com/items?itemName=humao.rest-client) extension installed; click "Send Request" above each block.
- `./test-requests.sh [base-url]` — plain curl, no extension needed.

## Testing

There's no fast local Maven test loop — see `CLAUDE.md` for why. All iteration goes through Docker.

**`UrlShortenerServiceStressTest`** is the real test suite: three small-scale stress tests against genuine Postgres/Redis via Testcontainers (not mocks) proving the cache actually shields the database under concurrent load, dedupe holds up across thousands of synthetic requests, and printing an actual cache-hit-vs-miss latency report. Needs a Docker daemon reachable from wherever it runs (Testcontainers spins up its own throwaway containers). To run it:

```bash
docker run --rm \
  -v "$(pwd)":/app \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -w /app \
  -e TESTCONTAINERS_RYUK_DISABLED=true \
  maven:3.9-eclipse-temurin-21 \
  mvn test -Dtest=UrlShortenerServiceStressTest
```

(`TESTCONTAINERS_RYUK_DISABLED` sidesteps some sibling-container complexity when Testcontainers itself is running inside a container via the mounted Docker socket; the containers it spins up still get cleaned up via a JVM shutdown hook either way.)

**`UrlShortenerApplicationTests`** is the original bare context-load smoke test generated by Spring Initializr. It needs a live Postgres/Redis to pass and currently has no Testcontainers setup of its own, so it isn't run as part of any normal workflow here — `mvn test` with no `-Dtest` filter would try to run it too and fail without one.

## Autoscaling

The HPA (`k8s/hpa.yaml`) scales the app Deployment on CPU utilization. `k8s/load-test-job.yaml` generates real HTTP load (a mix of unique-URL writes and repeated cache-hit reads, run as parallel in-cluster Job Pods) to actually trigger it - either directly:

```bash
kubectl apply -f k8s/load-test-job.yaml
kubectl get hpa -n url-shortener -w   # watch REPLICAS climb in real time
```

or with a click, from the "▶ Run Stress Test" panel on the Grafana Overview dashboard (see below). The Overview dashboard's **Min replicas** / **Max replicas** variables (top of the dashboard) control what the button actually does, not just labels: clicking it hits a small in-cluster trigger service (`k8s/loadtest-trigger.yaml`) that live-patches the HPA to those bounds (`kubectl patch hpa`) and scales the load-test Job's `parallelism`/`completions` to roughly match Max replicas — one load-generator Job pod per target replica, a simple heuristic for "enough aggregate load that the HPA has an actual reason to scale that high," not an exact CPU model. The trigger service is narrowly RBAC-scoped to only create/delete/get/list Jobs in the `url-shortener` namespace; it has no other permissions.

Delete the Job (`kubectl delete job load-test -n url-shortener`) to stop the load; the HPA scales back down on its own after a few minutes (a deliberate stabilization delay, to avoid flapping on brief spikes). A later `terraform apply` resets the HPA back to `app_min_replicas`/`app_max_replicas` (`terraform/variables.tf`) — the dashboard's live patch is meant for poking at it interactively, not a permanent config change.

## Grafana Dashboards

Two dashboards, auto-provisioned into Grafana via a labeled ConfigMap pair (`k8s/dashboards-configmap.yaml` / `terraform/monitoring.tf` - no manual "import" step) - no more ad-hoc PromQL against the bundled dashboards:

- **URL Shortener - Overview**: cache hit ratio, replica count over time (overlaid with the HPA's desired-replica count, so scale-up/scale-down events are visible directly), request rate by endpoint, the stress-test trigger button above, and a pod table.
- **URL Shortener - Pod Detail**: per-pod CPU, memory, request rate, and restart count, templated on a `$pod` variable. Click any row in the Overview dashboard's pod table to drill into that pod's detail view.

## Roadmap

- Additional Terraform cloud targets beyond AWS (the K8s-facing resources are already cloud-agnostic — see `terraform/aws.tf`'s comments for the pattern to follow)
