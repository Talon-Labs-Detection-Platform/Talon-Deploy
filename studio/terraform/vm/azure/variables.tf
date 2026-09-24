variable "name" {
  description = "Name prefix for every resource this stack creates."
  type        = string
  default     = "talon-studio"
}

variable "location" {
  description = "Azure region. Put it near the people using the console — this is one box, not a CDN."
  type        = string
  default     = "uksouth"
}

variable "domain" {
  description = <<-EOT
    The hostname the console is served on, e.g. studio.example.com. An A record
    must point at the public IP this stack outputs BEFORE the VM first boots, or
    Caddy cannot complete the ACME HTTP-01 challenge and you get no certificate.
    Apply -target=azurerm_public_ip.this first, set the record, then apply the rest.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", var.domain))
    error_message = "domain must be a bare hostname such as studio.example.com — no scheme, no path."
  }
}

variable "admin_email" {
  description = "Your login, and where Let's Encrypt sends certificate-expiry warnings."
  type        = string
}

variable "ssh_public_key" {
  description = "Full public key line, e.g. 'ssh-ed25519 AAAA... you@laptop'."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ", var.ssh_public_key))
    error_message = "ssh_public_key must be the full public key line, not a path or a fingerprint."
  }
}

variable "image_tag" {
  description = "Pinned Talon Studio release, e.g. v1.0.0."
  type        = string

  validation {
    # A moving tag makes "what is actually running" unanswerable and turns
    # rollback into guesswork. The bootstrap refuses these too; catching it at
    # plan time saves a boot.
    condition     = !contains(["latest", "beta", "edge", "dev", "main"], var.image_tag)
    error_message = "image_tag must be a pinned release, not a moving tag."
  }
}

variable "admin_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach SSH. Required, with no default: an inherited
    0.0.0.0/0 on port 22 is how a box ends up in a botnet.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs must name at least one network."
  }
}

variable "vm_size" {
  description = <<-EOT
    2 vCPU / 4 GB is the floor — the appliance runs Postgres, pySigma and the
    Next.js server in one container, and first boot syncs detection content.
    B2ms is the comfortable default.
  EOT
  type        = string
  default     = "Standard_B2ms"
}

variable "disk_size_gb" {
  description = "OS disk. Holds the embedded Postgres, the detection repos and synced content."
  type        = number
  default     = 64
}

variable "tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}

variable "cloud_init_url" {
  description = <<-EOT
    Where the bootstrap cloud-config is fetched from. The default is the
    published copy — the same bytes the install docs tell you to paste into a
    provider's user-data box — so this module works from a module archive, from
    the public talon-deploy repository, or from a checkout, without needing a
    path into any of them.
  EOT
  type        = string
  default     = "https://www.talonlabs.dev/studio/cloud-init.yaml"
}

variable "cloud_init_file" {
  description = <<-EOT
    A local cloud-config to use instead of fetching one. Set it to pin the
    bootstrap to a copy you have reviewed, or to apply without egress to
    talonlabs.dev. When set, no HTTP request is made at all.
  EOT
  type        = string
  default     = ""
}

variable "cloud_init_sha256" {
  description = <<-EOT
    Optional SHA-256 of the bootstrap, which the plan checks before the fetched
    file is ever used. Recommended for anything you would call production.

    Get it from https://www.talonlabs.dev/deploy-manifest.json, under
    "studio/cloud-init.yaml", or compute it from a copy you have read:

      curl -fsSL https://www.talonlabs.dev/studio/cloud-init.yaml | sha256sum

    Empty skips the check, which is the default because a pin that breaks on
    every legitimate update is a pin people learn to delete.
  EOT
  type        = string
  default     = ""
}
