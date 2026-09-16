variable "name" {
  description = "Cluster name and the prefix for every resource this stack creates."
  type        = string
  default     = "talon-control"
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
    CIDRs allowed to reach the EKS public API endpoint. Required, with no
    default: an inherited 0.0.0.0/0 puts the control plane's API in front of
    the whole internet.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs must name at least one network."
  }
}

variable "availability_zones" {
  description = "Two AZs in the region. RDS needs a subnet group spanning two even for a single-AZ instance."
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "availability_zones must name at least two."
  }
}

variable "kubernetes_version" {
  description = "EKS control-plane version."
  type        = string
  default     = "1.31"
}

variable "postgres_version" {
  description = "RDS Postgres major version."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "RDS instance size. db.t4g.small is comfortable for one console."
  type        = string
  default     = "db.t4g.small"
}

variable "backup_retention_days" {
  description = "Automated RDS backups. 0 disables them, which is never what you want for the database running your company."
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_days >= 1
    error_message = "backup_retention_days must be at least 1."
  }
}

variable "disk_size_gb" {
  description = "The /app/data PVC. Holds App Logs history, dev-session checkouts and the media library."
  type        = number
  default     = 40
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
  description = "Extra tags merged into every AWS resource."
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
