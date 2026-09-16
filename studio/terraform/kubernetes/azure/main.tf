# Talon Studio on AKS, with Postgres Flexible Server, installed from the chart
# in helm/talon-studio.
#
# Read cloud/terraform/self-host/README.md before choosing this over ../../vm/azure.
# Control is a single-writer appliance — one process, one volume, one database —
# so a cluster buys node repair and little else, at roughly ten times the
# monthly cost. This exists for organisations whose policy is "workloads run in
# Kubernetes", which is a real constraint and not a technical one.

locals {
  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Component = "talon-studio"
  })
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name}-vnet"
  address_space       = ["10.44.0.0/16"]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "${var.name}-nodes"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.44.1.0/24"]
}

# Flexible Server in VNet-integrated mode needs a subnet delegated to it and
# used by nothing else — hence a second subnet rather than sharing the nodes'.
resource "azurerm_subnet" "db" {
  name                 = "${var.name}-db"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.44.2.0/24"]

  delegation {
    name = "postgres"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Private DNS, because a VNet-integrated Flexible Server has no public name.
# Without this the cluster resolves the host to nothing and the app's first
# connection fails in a way that reads like a credentials problem.
resource "azurerm_private_dns_zone" "db" {
  name                = "${var.name}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "db" {
  name                  = "${var.name}-db-link"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.db.name
  virtual_network_id    = azurerm_virtual_network.this.id
  tags                  = local.tags
}

resource "random_password" "db" {
  length = 32
  # Azure rejects several punctuation characters in a Postgres admin password,
  # and a URL-unsafe one would break the connection string the chart assembles.
  override_special = "_-"
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "${var.name}-db"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  version             = var.postgres_version

  administrator_login    = "talon"
  administrator_password = random_password.db.result

  sku_name   = var.db_sku
  storage_mb = var.db_storage_mb

  delegated_subnet_id = azurerm_subnet.db.id
  private_dns_zone_id = azurerm_private_dns_zone.db.id
  # Public access is off by construction in VNet mode; stating it keeps the
  # intent visible in a `terraform show`.
  public_network_access_enabled = false

  backup_retention_days = var.backup_retention_days

  tags = local.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.db]

  lifecycle {
    # The database running your company should not be replaced by an in-place
    # edit to a sizing variable.
    prevent_destroy = true
  }
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = "detections"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = var.name
  kubernetes_version  = var.kubernetes_version
  tags                = local.tags

  default_node_pool {
    name           = "default"
    node_count     = var.node_count
    vm_size        = var.node_size
    vnet_subnet_id = azurerm_subnet.nodes.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    # Overlay: pod addresses come from their own space rather than eating the
    # subnet, which matters here because the VNet is deliberately small.
    network_plugin_mode = "overlay"
  }

  api_server_access_profile {
    authorized_ip_ranges = var.admin_cidrs
  }
}

# The secrets the chart would otherwise render from values. Kept in a Secret
# this stack owns so nothing credential-shaped lands in `helm get values`, and
# so the chart's own `secrets.existingSecret` path is the one in use. That path
# makes the chart render no Secret at all, which means every key it would have
# written has to be here — the chart's values.yaml lists them.
resource "random_password" "nextauth_secret" {
  length  = 64
  special = false
}

resource "random_password" "auth_secret" {
  length  = 64
  special = false
}

resource "random_password" "encryption_key" {
  length  = 64
  special = false
}

resource "random_password" "metrics_token" {
  length  = 48
  special = false
}

resource "random_password" "admin" {
  length           = 24
  override_special = "!#%*+-=?_"
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_secret_v1" "this" {
  metadata {
    name      = "${var.name}-secrets"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    NEXTAUTH_SECRET = random_password.nextauth_secret.result
    AUTH_SECRET     = random_password.auth_secret.result
    # WARNING: this lands in Terraform state, which is therefore as sensitive as
    # the database itself — encrypt the backend and restrict who can read it.
    # It decrypts every credential the appliance stores (SIEM connections, API
    # keys, git tokens); losing it makes a restored database ciphertext, so copy
    # it into your password manager too.
    TALON_ENCRYPTION_KEY = random_password.encryption_key.result
    TALON_METRICS_TOKEN  = random_password.metrics_token.result
    POSTGRES_URL = format(
      "postgresql://talon:%s@%s:5432/%s?sslmode=require",
      urlencode(random_password.db.result),
      azurerm_postgresql_flexible_server.this.fqdn,
      azurerm_postgresql_flexible_server_database.this.name,
    )
    # The embedded Postgres is off, but the chart still reads this key; an
    # absent one fails the render rather than defaulting to something weak.
    POSTGRES_PASSWORD      = random_password.db.result
    TALON_ADMIN_USERNAME   = "admin"
    TALON_ADMIN_EMAIL      = var.admin_email
    TALON_ADMIN_PASSWORD   = random_password.admin.result
  }

  type = "Opaque"
}

resource "helm_release" "talon_studio" {
  name      = var.name
  namespace = kubernetes_namespace_v1.this.metadata[0].name

  # The published chart. This pointed at oci://ghcr.io/... until 2026-09-16,
  # which answers 403 to anyone outside the organisation — the package is
  # private, so every customer apply failed at the pull.
  #
  # A Helm repository is an index.yaml and a tarball served over HTTPS — no
  # registry, no login, nothing to authorise. `helm repo add talon
  # https://www.talonlabs.dev/charts` is the same thing by hand.
  repository = var.chart_repository
  chart      = "talon-studio"
  version    = var.chart_version

  # Migrations run on boot, the data volume is ReadWriteOnce, and first boot
  # also initialises Postgres and syncs detection content — so let the pod
  # finish before reporting success, and give it room.
  wait    = true
  timeout = 1800

  values = [yamlencode({
    image = { tag = var.image_tag }
    # The chart refuses to render above 1 anyway; stating it keeps the reason
    # visible from here rather than only in the chart.
    replicaCount = 1
    secrets      = { existingSecret = kubernetes_secret_v1.this.metadata[0].name }
    postgres     = { external = true }
    persistence = {
      data = {
        enabled = true
        size    = "${var.disk_size_gb}Gi"
      }
    }
    config = {
      nextauthUrl = "https://${var.domain}"
      # Derive the origin from the request host as well, so a port-forward or a
      # temporary hostname still signs in.
      authTrustHost = "true"
    }
    ingress = {
      enabled     = true
      className   = var.ingress_class
      annotations = {
        # Validation runs and content sync stream progress; a proxy that buffers
        # them turns a live run into one that updates in bursts.
        "nginx.ingress.kubernetes.io/proxy-buffering"    = "off"
        "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600"
      }
      # A list of hosts, each with its own paths — this chart's shape, not the
      # single `host` string Control's chart takes.
      hosts = [{
        host  = var.domain
        paths = [{ path = "/", pathType = "Prefix" }]
      }]
      tls = var.tls_secret_name == "" ? [] : [{
        secretName = var.tls_secret_name
        hosts      = [var.domain]
      }]
    }
  })]

  depends_on = [azurerm_postgresql_flexible_server_database.this]
}
