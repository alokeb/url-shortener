# AWS is ONE EXAMPLE cloud target, not the only one this is designed for - it's the worked
# reference implementation for "how do I add a cloud provider to this," not a special case
# baked into the rest of the config. Everything outside this file (namespace.tf, secret.tf,
# postgres.tf, redis.tf, app.tf, monitoring.tf) only ever talks to "a Kubernetes cluster,"
# with zero AWS-specific knowledge - adding gcp.tf or azure.tf later, following this same
# shape (VM + firewall + SSH keypair + k3s install script + kubeconfig fetch to a static
# path, gated the same way credentials.tfvars.example describes), plugs into all of that
# without changing a line of it.
#
# Everything in this file only runs when deployment_target = "aws" (variables.tf) - the
# `count = var.deployment_target == "aws" ? 1 : 0` on every resource here is Terraform's way
# of making a resource conditional (it doesn't have a real if/else for resource blocks).
# count = 0 means "this resource doesn't exist at all," not "exists but empty."

# Generates a fresh SSH keypair for THIS deployment rather than reusing any key already on
# your machine - private key never leaves ${path.module}/generated/ (gitignored), and gets
# deleted along with everything else on `terraform destroy`.
resource "tls_private_key" "ssh" {
  count     = var.deployment_target == "aws" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "ssh_private_key" {
  count           = var.deployment_target == "aws" ? 1 : 0
  content         = tls_private_key.ssh[0].private_key_pem
  filename        = "${path.module}/generated/aws-ssh-key.pem"
  file_permission = "0600"
}

resource "aws_key_pair" "this" {
  count      = var.deployment_target == "aws" ? 1 : 0
  key_name   = "url-shortener-terraform"
  public_key = tls_private_key.ssh[0].public_key_openssh
}

# Only two ports open: 22 (SSH - needed to fetch the kubeconfig and load the app image, see
# below) and 6443 (the k3s/Kubernetes API server itself, so kubectl/terraform from this
# machine can actually reach the cluster). The app itself is deliberately NOT exposed here -
# reach it the same way as local minikube, via `kubectl port-forward`, over the SSH-tunneled
# kubeconfig this file produces. Opening it directly would need its own ingress rule and is
# a separate, deliberate decision - not a default.
resource "aws_security_group" "k3s" {
  count       = var.deployment_target == "aws" ? 1 : 0
  name        = "url-shortener-k3s"
  description = "SSH + k3s API access for the url-shortener AWS deployment"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "k3s Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Latest Ubuntu 22.04 LTS from Canonical's own AWS account (099720109477 is Canonical's
# well-known, publicly documented account ID for official Ubuntu AMIs) - resolved fresh at
# apply time rather than hardcoding an AMI ID, which is region-specific and goes stale.
data "aws_ami" "ubuntu" {
  count       = var.deployment_target == "aws" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "k3s" {
  count                       = var.deployment_target == "aws" ? 1 : 0
  ami                         = data.aws_ami.ubuntu[0].id
  instance_type               = var.aws_instance_type
  key_name                    = aws_key_pair.this[0].key_name
  vpc_security_group_ids      = [aws_security_group.k3s[0].id]
  associate_public_ip_address = true

  # 20GiB is within the free tier's 30GiB/month EBS allowance even as the only volume on the
  # account - k3s + Docker-imported images + Postgres's PVC (an actual local directory on
  # this same disk, since k3s's default StorageClass is host-path-backed, not a separate
  # cloud disk resource) all share this one volume.
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  # Runs once, automatically, the first time this instance boots - no SSH/remote-exec
  # needed to install k3s itself. --write-kubeconfig-mode 644 makes k3s's generated
  # kubeconfig world-readable (default is 600, root-only) so the null_resource below can
  # read it over SSH as the "ubuntu" user rather than needing sudo over SCP.
  user_data = <<-EOF
    #!/bin/bash
    set -e
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
  EOF

  tags = {
    Name = "url-shortener-k3s"
  }
}

# k3s's own generated kubeconfig points at "127.0.0.1" (correct from ON the instance, wrong
# from here) - this fetches it over SSH and rewrites that to the instance's real public IP,
# producing a kubeconfig this machine's kubectl/terraform can actually use. Written to a
# STATIC path (generated/aws-kubeconfig) specifically so versions.tf's provider blocks can
# reference a plain, always-the-same string - a provider config CAN'T reference a resource
# attribute like aws_instance.k3s[0].public_ip directly (providers are configured before any
# resource exists), so the static-path-plus-depends_on combination is the actual workaround.
resource "null_resource" "aws_kubeconfig" {
  count      = var.deployment_target == "aws" ? 1 : 0
  depends_on = [aws_instance.k3s, local_sensitive_file.ssh_private_key]

  triggers = {
    instance_id = aws_instance.k3s[0].id
  }

  provisioner "local-exec" {
    command = <<-EOF
      set -e
      mkdir -p ${path.module}/generated
      KEY="${path.module}/generated/aws-ssh-key.pem"
      HOST="${aws_instance.k3s[0].public_ip}"
      echo "Waiting for k3s to finish installing on $HOST..."
      for i in $(seq 1 30); do
        if ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$HOST "test -f /etc/rancher/k3s/k3s.yaml" 2>/dev/null; then
          echo "k3s is ready."
          break
        fi
        sleep 10
      done
      scp -i "$KEY" -o StrictHostKeyChecking=no ubuntu@$HOST:/etc/rancher/k3s/k3s.yaml ${path.module}/generated/aws-kubeconfig
      sed -i "s/127.0.0.1/$HOST/" ${path.module}/generated/aws-kubeconfig
    EOF
  }
}
