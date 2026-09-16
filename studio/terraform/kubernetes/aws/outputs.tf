output "cluster_name" {
  description = "Wire up kubectl: aws eks update-kubeconfig --name <this> --region <region>."
  value       = module.eks.cluster_name
}

output "url" {
  description = "The console, once a record points at the ingress address."
  value       = "https://${var.domain}"
}

output "ingress_address" {
  description = "Point your DNS record here. Empty until the ingress controller has provisioned a load balancer."
  value       = "kubectl -n ${var.namespace} get ingress ${var.name}-talon-studio -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "admin_password" {
  description = "Generated password for admin_email. Change it after the first sign-in."
  value       = random_password.admin.result
  sensitive   = true
}

output "encryption_key" {
  description = <<-EOT
    ESCROW THIS IN YOUR PASSWORD MANAGER. It decrypts every credential the
    console stores; a restored database without it is ciphertext. It is also in
    Terraform state, which makes that state as sensitive as the database.
  EOT
  value     = random_password.encryption_key.result
  sensitive = true
}
