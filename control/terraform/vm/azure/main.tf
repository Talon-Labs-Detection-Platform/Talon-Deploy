# Talon Control on one Azure Linux VM: Docker Compose, a private Postgres, and
# Caddy terminating TLS. The AWS stack next door, in Azure's vocabulary.

locals {
  # WHERE THE BOOTSTRAP COMES FROM. This was
  # file("${path.module}/../../../../../deploy/cloud-init.yaml") until
  # 2026-09-16 — a path out of this module and into the product repo, which is
  # private. It resolved for us and for nobody else: read from a module archive
  # or from the public talon-deploy repository, those `../` walk off into the
  # caller's filesystem and the plan fails on a missing file. Fetching the
  # published copy makes every layout identical, and means the bootstrap
  # Terraform boots is byte-for-byte the one the install docs tell you to paste.
  cloud_init_source = var.cloud_init_file != "" ? file(var.cloud_init_file) : data.http.cloud_init[0].response_body

  # The single bootstrap, shared with the hand-install path and the AWS stack.
  # replace() rather than templatefile(): the file is a working cloud-config a
  # human can paste as-is, and templatefile would demand every shell `${VAR}` in
  # it be escaped, which is precisely how the paste-able copy and the Terraform
  # copy drift apart.
  cloud_init = replace(replace(replace(replace(
    local.cloud_init_source,
    "__DOMAIN__", var.domain),
    "__ADMIN_EMAIL__", var.admin_email),
    "__SSH_KEY__", var.ssh_public_key),
    "__IMAGE_TAG__", var.image_tag)

  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Component = "talon-control"
  })
}

# Skipped entirely when cloud_init_file is set, so an apply with no egress to
# talonlabs.dev needs no network exception — just a local copy.
data "http" "cloud_init" {
  count = var.cloud_init_file == "" ? 1 : 0
  url   = var.cloud_init_url

  # A 200 carrying something other than a cloud-config is worse than a 404: it
  # boots a machine that comes up bare and silent. Fail at plan time instead.
  lifecycle {
    postcondition {
      condition     = startswith(self.response_body, "#cloud-config")
      error_message = "${var.cloud_init_url} did not return a cloud-config. Check the URL, or set cloud_init_file to a reviewed local copy."
    }

    # What this is for. The paste path has a human in the loop — you download
    # the file, read it, paste it. This path has none: what comes back becomes
    # user-data and runs as root on first boot. HTTPS authenticates the server;
    # it does not tell you the bytes are the ones you reviewed. Pinning does.
    #
    # Empty by default, deliberately. Defaulting it to the digest of the day
    # would fail every plan the moment the bootstrap is legitimately updated,
    # which trains people to delete the check.
    postcondition {
      condition     = var.cloud_init_sha256 == "" || sha256(self.response_body) == lower(var.cloud_init_sha256)
      error_message = "${var.cloud_init_url} does not match cloud_init_sha256. Got ${sha256(self.response_body)}. Either the bootstrap was updated and the pin is stale, or the file is not what you reviewed — read it before moving the pin."
    }
  }
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name}-vnet"
  address_space       = ["10.42.0.0/16"]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_subnet" "this" {
  name                 = "${var.name}-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.42.1.0/24"]
}

# Static, and created before the VM, so the DNS record can exist before first
# boot — Caddy cannot get a certificate for a name that does not resolve to it.
resource "azurerm_public_ip" "this" {
  name                = "${var.name}-ip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_security_group" "this" {
  name                = "${var.name}-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  # SSH is restricted to CIDRs you name. variables.tf requires the list rather
  # than defaulting it, so an open SSH port is something you typed.
  security_rule {
    name                       = "ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.admin_cidrs
    destination_address_prefix = "*"
  }

  # 80 is open because Caddy needs the HTTP-01 challenge to issue and renew the
  # certificate; it redirects everything else to 443. Closing it does not harden
  # the box, it just stops the certificate renewing 60 days later.
  security_rule {
    name                       = "http"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "https"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "this" {
  name                = "${var.name}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this.id
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = var.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = var.vm_size
  admin_username      = "talon"
  tags                = local.tags

  network_interface_ids = [azurerm_network_interface.this.id]

  # Azure wants a key for the admin user it creates; cloud-init then creates the
  # same `talon` user with the same key. Harmless overlap, and required —
  # disable_password_authentication with no key is rejected at plan time.
  admin_ssh_key {
    username   = "talon"
    public_key = var.ssh_public_key
  }

  custom_data = base64encode(local.cloud_init)

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    # Holds Postgres, App Logs history, the Claude Code transcripts dev sessions
    # resume from, and git checkouts with uncommitted work in them.
    disk_size_gb = var.disk_size_gb
  }

  source_image_reference {
    publisher = "Debian"
    offer     = "debian-13"
    sku       = "13-gen2"
    version   = "latest"
  }

  lifecycle {
    # An image refresh should not silently replace the box holding your data.
    # Bump it deliberately:
    #   terraform apply -replace=azurerm_linux_virtual_machine.this
    ignore_changes = [source_image_reference, custom_data]
  }
}
