# Same not-a-real-secret placeholder values as .env and k8s/secret.yaml (see CLAUDE.md for
# why this project deliberately keeps these committed in the open) - default values here mean
# `terraform apply` works with zero setup, but every value can still be overridden via a
# terraform.tfvars file (see terraform.tfvars.example) or -var flags without editing this file.

variable "db_name" {
  description = "Postgres database name"
  type        = string
  default     = "urlshortener"
}

variable "db_user" {
  description = "Postgres username"
  type        = string
  default     = "urlshortener"
}

variable "db_password" {
  description = "Postgres password"
  type        = string
  default     = "local-dev-only-not-a-real-secret"
  sensitive   = true
}

variable "minikube_memory_mb" {
  description = "Memory (MB) allocated to the minikube node container (deployment_target = \"local\" only)"
  type        = number
  default     = 20000
}

# "local" = minikube on this machine (what every prior session in this project used).
# "aws"   = a single EC2 instance running k3s (see aws.tf) - a real, separate cluster,
# reachable over the internet, at the cost of things a laptop-local minikube never had to
# worry about: real money, a security group controlling what's reachable, and no
# `minikube image load` shortcut for getting the app image onto the node (see bootstrap.tf).
variable "deployment_target" {
  description = "Where to deploy: \"local\" (minikube) or \"aws\" (EC2 + k3s)"
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "aws"], var.deployment_target)
    error_message = "deployment_target must be \"local\" or \"aws\"."
  }
}

# --- Minimum system requirements (whatever machine ends up running this - EC2, another
# cloud's VM, or the minikube host itself) ---
#   Without monitoring: ~1 vCPU, ~1GB RAM
#   With monitoring:    ~2 vCPU, ~3GB RAM  (kube-prometheus-stack alone needs 2GB+)
# The defaults below are sized for the "without monitoring" tier, with enough headroom for
# k3s/minikube's own overhead on top - NOT the much larger numbers used during this
# project's earlier host-stress-test session (that was against a 12-core/30GB local machine).
# Override via terraform.tfvars for a bigger box if you want to reproduce that scale of test
# again, or if you're running with enable_monitoring = true on the "aws" target.
variable "app_min_replicas" {
  description = "HPA floor for the app Deployment"
  type        = number
  default     = 1
}

variable "app_max_replicas" {
  description = "HPA ceiling for the app Deployment"
  type        = number
  default     = 3
}

variable "app_cpu_target_percent" {
  description = "HPA target: average CPU utilization (% of each Pod's CPU request) before scaling out"
  type        = number
  default     = 50
}

variable "app_cpu_request" {
  type    = string
  default = "100m"
}
variable "app_cpu_limit" {
  type    = string
  default = "300m"
}
# 256Mi was the original guess here and was WRONG - confirmed by actually deploying it:
# this app's real resting JVM footprint (Tomcat + Hibernate + Spring context) is ~300-400Mi,
# observed directly in an earlier session on this same project. A limit below that isn't a
# tight-but-workable constraint, it's a guaranteed problem - the JVM spends so much time
# fighting GC to stay under a limit it can't actually fit under that health-check responses
# start timing out, which makes kubelet kill and restart the container on failed liveness
# checks (confirmed: this is exactly what happened when 256Mi was tested). 450Mi leaves real
# headroom above that observed baseline. Combined with Postgres+Redis+k3s's own overhead,
# this makes the ~1GB "without monitoring" minimum genuinely tight (expected, not a bug) but
# workable, since requests (not limits) are what's actually checked at scheduling time.
variable "app_memory_request" {
  type    = string
  default = "350Mi"
}
variable "app_memory_limit" {
  type    = string
  default = "450Mi"
}

variable "postgres_cpu_request" {
  type    = string
  default = "50m"
}
variable "postgres_cpu_limit" {
  type    = string
  default = "200m"
}
variable "postgres_memory_request" {
  type    = string
  default = "128Mi"
}
variable "postgres_memory_limit" {
  type    = string
  default = "256Mi"
}

variable "redis_cpu_request" {
  type    = string
  default = "20m"
}
variable "redis_cpu_limit" {
  type    = string
  default = "100m"
}
variable "redis_memory_request" {
  type    = string
  default = "32Mi"
}
variable "redis_memory_limit" {
  type    = string
  default = "64Mi"
}

# True by default because it's already proven working against local minikube (see
# CLAUDE.md), which has plenty of room for it. On a machine only sized to the "without
# monitoring" minimum above (~1GB RAM), set this to false in terraform.tfvars - the full
# stack (kube-prometheus-stack alone needs 2GB+) simply won't fit otherwise.
variable "enable_monitoring" {
  description = "Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager)"
  type        = bool
  default     = true
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# Default meets the "without monitoring" minimum above (1 vCPU / 1GiB RAM) and happens to
# also be AWS's free-tier-eligible size - a nice bonus, not the reason it was picked. Any
# instance type meeting (or exceeding, for enable_monitoring = true) the requirements above
# works fine here.
variable "aws_instance_type" {
  type    = string
  default = "t3.micro"
}

# 0.0.0.0/0 (i.e. "anywhere on the internet") because a home/office IP can change - fine for
# a short-lived learning deployment, but the honest tradeoff is anyone who finds this
# instance's IP can attempt to SSH into it (though still needs the private key Terraform
# generates - see aws.tf). Narrow this to your own IP/32 for anything left running longer.
variable "ssh_allowed_cidr" {
  type    = string
  default = "0.0.0.0/0"
}

# Read from credentials.auto.tfvars (see credentials.tfvars.example - copy it, fill it in,
# never commit the copy) rather than the AWS CLI's own ~/.aws/credentials chain, since the
# ask here was an explicit file to edit, not an implicit external setup step. Defaulting to
# "" (not a hard requirement) means deployment_target = "local" still works with zero AWS
# setup at all - these are only ever read when aws.tf's resources actually exist.
variable "aws_access_key_id" {
  type      = string
  default   = ""
  sensitive = true
}

variable "aws_secret_access_key" {
  type      = string
  default   = ""
  sensitive = true
}
