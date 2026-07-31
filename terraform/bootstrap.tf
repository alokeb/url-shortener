# The imperative half of this setup - see versions.tf's comment on why these are
# null_resource + local-exec (shelling out to a real command) instead of "real" Terraform
# resources: minikube/EC2 provisioning is covered elsewhere (aws.tf), but GETTING the app
# image onto whichever cluster is running isn't something any Terraform provider manages
# declaratively either way.
#
# `triggers` is what null_resource uses instead of "real" resource attributes to decide
# whether to re-run its provisioner on `terraform apply` - if none of the listed values
# changed since last apply, Terraform skips re-running it entirely (matching how a normal
# resource skips re-creating itself when nothing about it changed).

resource "null_resource" "minikube_cluster" {
  count = var.deployment_target == "local" ? 1 : 0

  triggers = {
    memory_mb = var.minikube_memory_mb
  }

  provisioner "local-exec" {
    # `minikube start` is itself idempotent - safe to run against an already-running cluster
    # with matching config, it just no-ops quickly. It is NOT smart enough to notice a
    # *changed* --memory value on an already-running cluster though (that needs `minikube
    # delete` first, same gotcha documented in CLAUDE.md) - this only handles the "cluster
    # doesn't exist or is stopped" case cleanly.
    command = "minikube start --driver=docker --memory=${var.minikube_memory_mb}"
  }

  # Confirmed by testing: without this, `terraform destroy` removes this resource from
  # Terraform's OWN tracking but leaves minikube itself running - destroying a null_resource
  # is just bookkeeping unless it has explicit instructions for what "destroy" should
  # actually DO. `when = destroy` is what makes that happen. Uses `minikube stop` (not
  # `delete`) so the cluster/PVC data can come back with a plain `terraform apply` later,
  # consistent with how minikube's been used everywhere else in this project.
  provisioner "local-exec" {
    when    = destroy
    command = "minikube stop"
  }
}

resource "null_resource" "metrics_server" {
  count      = var.deployment_target == "local" ? 1 : 0
  depends_on = [null_resource.minikube_cluster]

  provisioner "local-exec" {
    # k3s (the aws.tf path) ships its own equivalent metrics pipeline out of the box -
    # nothing to enable there, this step is minikube-specific.
    command = "minikube addons enable metrics-server"
  }
}

# Rebuilds the app image only when the actual inputs to that image change - not on every
# `terraform apply`. sha256() over a concatenation of every source file's own hash means ANY
# change under src/, or to the Dockerfile/pom.xml themselves, produces a different trigger
# value; an unrelated terraform.tfvars edit does not. Shared by both deployment targets -
# only what happens to the built image afterward (local-only / aws-only resources below)
# differs.
locals {
  app_source_files = fileset("${path.module}/..", "src/**")
  app_source_hash = sha256(join("", [
    for f in local.app_source_files : filesha256("${path.module}/../${f}")
  ]))
  app_build_inputs_hash = sha256(join("", [
    local.app_source_hash,
    filesha256("${path.module}/../Dockerfile"),
    filesha256("${path.module}/../pom.xml"),
  ]))
}

resource "null_resource" "app_image_build" {
  triggers = {
    build_inputs_hash = local.app_build_inputs_hash
  }

  provisioner "local-exec" {
    # Built directly via `docker build` (not `docker compose build`) so this stays
    # self-contained and doesn't assume docker-compose.yml's env/network setup exists - all
    # this needs is the Dockerfile and build context.
    command = "docker build -t url-shortener-app:latest ${path.module}/.."
  }
}

resource "null_resource" "app_image_load_local" {
  count      = var.deployment_target == "local" ? 1 : 0
  depends_on = [null_resource.minikube_cluster, null_resource.app_image_build]

  triggers = {
    build_inputs_hash = local.app_build_inputs_hash
  }

  provisioner "local-exec" {
    # minikube's Docker driver runs its own, separate Docker daemon - it does NOT see images
    # built against the host's daemon automatically (see app.tf's imagePullPolicy comment).
    command = "minikube image load url-shortener-app:latest"
  }
}

resource "null_resource" "app_image_load_aws" {
  count      = var.deployment_target == "aws" ? 1 : 0
  depends_on = [null_resource.aws_kubeconfig, null_resource.app_image_build]

  triggers = {
    build_inputs_hash = local.app_build_inputs_hash
  }

  provisioner "local-exec" {
    # No minikube-style shortcut here, and no container registry either (avoids the extra
    # AWS resource/cost of ECR just for this) - instead the image is streamed straight over
    # SSH and imported directly into k3s's own containerd image store on the remote host.
    # `docker save | gzip` -> pipe over ssh -> `gunzip | k3s ctr images import -` moves the
    # image in one pass without ever writing an intermediate file on either end.
    command = <<-EOF
      set -e
      KEY="${path.module}/generated/aws-ssh-key.pem"
      HOST="${var.deployment_target == "aws" ? aws_instance.k3s[0].public_ip : ""}"
      docker save url-shortener-app:latest | gzip | \
        ssh -i "$KEY" -o StrictHostKeyChecking=no ubuntu@$HOST \
        "gunzip | sudo k3s ctr images import -"
    EOF
  }
}
