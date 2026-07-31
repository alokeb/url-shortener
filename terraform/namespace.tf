# Direct HCL translation of k8s/namespace.yaml - see that file's comment for why a
# namespace exists at all. Both k8s/ (plain kubectl) and this terraform/ directory describe
# the SAME end state via two different tools; don't `kubectl apply -f k8s/` and
# `terraform apply` against the same cluster at the same time, they'll fight over ownership
# of identical resource names.
resource "kubernetes_namespace" "url_shortener" {
  depends_on = [null_resource.minikube_cluster]

  metadata {
    name = "url-shortener"
  }
}
