# Terraform basics, for reference since this is the first Terraform in this project:
# - `terraform { required_providers { ... } }` declares WHICH provider plugins this config
#   needs and which versions are acceptable - Terraform downloads these into a local
#   .terraform/ directory on `terraform init` (gitignored, like node_modules/target/ etc.).
# - Each `provider "x" { ... }` block below is that provider's actual connection config.
#   "kubernetes", "helm", and "kubectl" all need to know WHICH cluster to talk to - the
#   `local.kube_*` values just below switch that between minikube's kubeconfig
#   (deployment_target = "local") and the one aws.tf's null_resource.aws_kubeconfig fetches
#   and rewrites (deployment_target = "aws"). Same K8s-facing resources either way
#   (namespace.tf, secret.tf, postgres.tf, redis.tf, app.tf, monitoring.tf) - only WHERE they
#   get pointed changes. See variables.tf's deployment_target for the cloud-agnosticism this
#   enables: adding another cloud provider later is a new <provider>.tf file (aws.tf's
#   pattern: VM + firewall + SSH keypair + k3s install + kubeconfig fetch to a static path),
#   not a rewrite of anything in this list.
# - There's no official Terraform provider for minikube OR for "a generic cloud VM" (every
#   cloud has its own resource types by design) - bootstrap.tf/aws.tf handle actual cluster
#   provisioning via `local-exec` provisioners (Terraform shelling out to real commands)
#   rather than "real" declarative resources for that specific part. Deliberate, pragmatic
#   gap, not an oversight.

terraform {
  required_version = ">= 1.5"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    # kubectl (community provider, not hashicorp/kubernetes) is used ONLY for the
    # ServiceMonitor resource in monitoring.tf. Reason: ServiceMonitor is a Custom Resource
    # (CRD) defined by the Prometheus Operator, which the helm_release.monitoring below
    # installs - hashicorp/kubernetes's own generic `kubernetes_manifest` resource validates
    # a manifest's schema against the CRD at PLAN time, which fails the very first time you
    # ever run this (the CRD doesn't exist yet at plan time - it's created by a resource
    # later in the same plan). kubectl_manifest applies raw YAML without that plan-time
    # schema check, sidestepping the chicken-and-egg problem entirely.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    # Only actually used when deployment_target = "aws" (see aws.tf) - having them declared
    # here doesn't force AWS credentials to exist for the "local" path, since none of the
    # resources that need them get created (count = 0) unless deployment_target = "aws".
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

locals {
  # A provider block's arguments can't reference another resource's attributes directly
  # (providers are configured before Terraform knows what resources will even exist) - which
  # is exactly why aws.tf's null_resource.aws_kubeconfig writes its fetched-and-rewritten
  # kubeconfig to this SAME static path every time, rather than somewhere derived from the
  # EC2 instance's own attributes. These two locals are safe for a provider block because
  # they only depend on a plain input variable, never on a resource.
  kube_config_path = var.deployment_target == "aws" ? "${path.module}/generated/aws-kubeconfig" : pathexpand("~/.kube/config")
  # k3s's own generated kubeconfig names its context "default"; minikube's is "minikube".
  kube_context = var.deployment_target == "aws" ? "default" : "minikube"
}

provider "kubernetes" {
  config_path    = local.kube_config_path
  config_context = local.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = local.kube_config_path
    config_context = local.kube_context
  }
}

provider "kubectl" {
  config_path       = local.kube_config_path
  config_context    = local.kube_context
  load_config_file  = true
}

provider "aws" {
  region = var.aws_region
  # Falls back to an obviously-fake placeholder (not "" or null) when unset. This looks
  # backwards, but it's the one combination that actually works: the AWS provider needs SOME
  # static credential to resolve successfully at configure time no matter what (confirmed by
  # testing - skip_credentials_validation etc. below only skip VALIDATING it, not needing one
  # to exist at all), and an empty/absent value makes it fall through to real credential
  # chains instead (env vars, ~/.aws/credentials, EC2 IMDS) - which then genuinely fail, or
  # for IMDS, hang until timeout, when this obviously isn't running on real AWS. A
  # syntactically-present-but-fake credential satisfies that requirement without needing
  # real AWS access at all for deployment_target = "local".
  access_key = var.aws_access_key_id != "" ? var.aws_access_key_id : "unused-for-local-deployment"
  secret_key = var.aws_secret_access_key != "" ? var.aws_secret_access_key : "unused-for-local-deployment"

  # Without these, the AWS provider tries to authenticate (an STS "who am I" call, plus a
  # check against the EC2 metadata service/IMDS - which times out, since this obviously
  # isn't running on an EC2 instance) just to configure itself, even when
  # deployment_target = "local" and zero aws_* resources exist in the plan at all - which is
  # exactly the failure `terraform plan` hit above. These skip that eager check; a REAL
  # request (creating the EC2 instance) still needs real credentials regardless - this only
  # defers the check to when they're actually needed.
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  skip_metadata_api_check     = true
}
