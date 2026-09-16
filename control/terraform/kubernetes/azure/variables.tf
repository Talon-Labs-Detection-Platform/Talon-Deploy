variable "name" {
  description = "Cluster name and the prefix for every resource this stack creates."
  type        = string
  default     = "talon-control"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "uksouth"
}

variable "namespace" {
  description = "Kubernetes namespace for the release."
  type        = string
  default     = "talon-control"
}

variable "domain" {
  description = "Hostname the console is served on. Point a record at the ingress address after the first apply."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", var.domain))
    error_message = "domain must be a bare hostname such as control.example.com — no scheme, no path."
  }
}

variable "admin_email" {
  description = "Seeded admin login. The password is generated and surfaced as a stack output."
  type        = string
}

variable "image_tag" {
  description = "Pinned Talon Control release, e.g. v1.0.0-beta.1. Empty falls back to the chart's appVersion."
  type        = string
  default     = ""

  validation {
    condition     = !contains(["latest", "beta", "edge", "dev", "main"], var.image_tag)
    error_message = "image_tag must be a pinned release, not a moving tag."
  }
}

variable "admin_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the AKS API server. Required, with no default: an
    inherited 0.0.0.0/0 puts the control plane's API in front of the whole
    internet.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs must name at least one network."
  }
}

variable "kubernetes_version" {
  description = "AKS control-plane version."
  type        = string
  default     = "1.31"
}

variable "node_count" {
  description = "Nodes in the default pool. Two so a node can be drained without taking the console down."
  type        = number
  default     = 2
}

variable "node_size" {
  description = "Node VM size. Dev sessions run pnpm builds inside the app pod, so do not go below 2 vCPU / 8 GB."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "postgres_version" {
  description = "Flexible Server Postgres major version."
  type        = string
  default     = "16"
}

variable "db_sku" {
  description = "Flexible Server SKU. B_Standard_B1ms is the cheapest that works for one console."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "db_storage_mb" {
  description = "Flexible Server storage. Azure will not shrink this later."
  type        = number
  default     = 32768
}

variable "backup_retention_days" {
  description = "Flexible Server backups. Never 0 for the database running your company."
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_days >= 7
    error_message = "backup_retention_days must be at least 7 — Azure's own minimum."
  }
}

variable "disk_size_gb" {
  description = "The /app/data PVC. Holds App Logs history, dev-session checkouts and the media library."
  type        = number
  default     = 40
}

variable "storage_class" {
  description = "StorageClass for the data PVC. managed-csi is ReadWriteOnce, which is what the chart wants."
  type        = string
  default     = "managed-csi"
}

variable "ingress_class" {
  description = "IngressClass to attach the release's Ingress to. Install the controller before applying."
  type        = string
  default     = "nginx"
}

variable "tls_secret_name" {
  description = "Secret holding the certificate, e.g. one cert-manager writes. Empty serves plain HTTP."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Extra tags merged into every Azure resource."
  type        = map(string)
  default     = {}
}

variable "chart_repository" {
  description = <<-EOT
    The Helm repository serving the chart. The default is the published one,
    which is static files over HTTPS and needs no credentials. Point it at a
    mirror if your clusters may not reach talonlabs.dev.
  EOT
  type        = string
  default     = "https://www.talonlabs.dev/charts"
}

variable "chart_version" {
  description = "Chart version to install. Pin it: an unpinned chart makes \"what is deployed\" unanswerable."
  type        = string
  default     = "0.4.0"
}
