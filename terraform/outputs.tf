# `terraform output` (or these printed automatically at the end of `terraform apply`) - the
# "what do I actually do now that this finished" cheat sheet, so you're not stuck.

output "kubectl_command_hint" {
  description = "How to point kubectl at whichever cluster this deployed to"
  value = var.deployment_target == "aws" ? (
    "export KUBECONFIG=${path.module}/generated/aws-kubeconfig  (then kubectl get pods -A)"
    ) : (
    "kubectl already points at minikube by default - kubectl get pods -A"
  )
}

output "app_access_command" {
  description = "How to reach the app itself"
  value       = "kubectl port-forward -n url-shortener svc/url-shortener-app 8080:8080   (then open http://localhost:8080)"
}

output "grafana_access_command" {
  description = "How to reach Grafana (only meaningful if enable_monitoring = true)"
  value = var.enable_monitoring ? (
    "kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80   (then open http://localhost:3000 - auto-logged in as admin)"
  ) : "enable_monitoring = false, no Grafana deployed"
}

output "aws_instance_public_ip" {
  description = "Public IP of the EC2 instance (deployment_target = \"aws\" only)"
  value       = var.deployment_target == "aws" ? aws_instance.k3s[0].public_ip : null
}

output "aws_ssh_command" {
  description = "SSH into the EC2 instance directly, e.g. to check k3s/cloud-init logs (deployment_target = \"aws\" only)"
  value       = var.deployment_target == "aws" ? "ssh -i ${path.module}/generated/aws-ssh-key.pem ubuntu@${aws_instance.k3s[0].public_ip}" : null
}
