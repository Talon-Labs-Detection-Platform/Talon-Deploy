# Talon Studio on one EC2 instance: the appliance image (Next.js app, embedded
# Postgres, embedded pySigma) on one /data volume, behind Caddy terminating TLS.
# The same shape docs/operators/deploy.md describes by hand, expressed as code.

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

  # The single bootstrap, shared with the hand-install path and the Azure stack.
  # replace() rather than templatefile(): the file is a working cloud-config a
  # human can paste as-is, and templatefile would demand every shell `${VAR}` in
  # it be escaped, which is precisely how the paste-able copy and the Terraform
  # copy drift apart.
  # No admin password: the appliance generates one on first boot, so none
  # passes through user-data or Terraform state.
  cloud_init = replace(replace(replace(replace(
    local.cloud_init_source,
    "__DOMAIN__", var.domain),
    "__ADMIN_EMAIL__", var.admin_email),
    "__SSH_KEY__", var.ssh_public_key),
    "__IMAGE_TAG__", var.image_tag)

  tags = merge(var.tags, {
    Name      = var.name
    ManagedBy = "terraform"
    Component = "talon-studio"
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

# Debian 13 (trixie), owned by the Debian project's own account. Filtered rather
# than pinned: an AMI id is region-specific and goes stale every time Debian
# publishes a patched image, and a stale id fails at apply with an unhelpful
# error. most_recent is safe here because a replacement only takes effect on an
# instance replacement, which is a plan you read first.
data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"]

  filter {
    name   = "name"
    values = ["debian-13-amd64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "Talon Studio: SSH from admins, HTTP/HTTPS from the internet"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

# SSH is restricted to CIDRs you name. There is no default of 0.0.0.0/0 for
# this rule on purpose — variables.tf requires the list rather than defaulting
# it, so an open SSH port is something you typed, not something you inherited.
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.admin_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "SSH from an administrator network"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# 80 is open because Caddy needs the HTTP-01 challenge to issue and renew the
# certificate; it redirects everything else to 443. Closing it does not harden
# the box, it just stops the certificate renewing 60 days later.
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.this.id
  description       = "ACME HTTP-01 challenge and the redirect to HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "The console"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Image pulls, ACME, AI providers, GitHub"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.debian.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  user_data              = local.cloud_init

  # Re-running cloud-init on an existing box would regenerate nothing (the
  # installer is idempotent and refuses to mint a second encryption key), but a
  # changed bootstrap should still roll a fresh instance rather than leave the
  # running one describing a config it never applied.
  user_data_replace_on_change = true

  root_block_device {
    volume_size = var.disk_size_gb
    volume_type = "gp3"
    encrypted   = true
    # The volume holds the embedded Postgres, the git-backed detection repos and
    # the synced detection content — everything the appliance is.
    delete_on_termination = false
  }

  metadata_options {
    # IMDSv2 only. The console makes outbound HTTP on behalf of agents, so a
    # v1-reachable metadata endpoint is one SSRF away from instance credentials.
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  tags = local.tags

  lifecycle {
    # An AMI refresh should not silently replace the box holding your data.
    # Bump it deliberately: terraform apply -replace=aws_instance.this
    ignore_changes = [ami]
  }
}

# Allocated separately from the instance so the address survives a replacement,
# and so you can create the DNS record before the first boot — Caddy cannot get
# a certificate for a name that does not resolve to it yet.
resource "aws_eip" "this" {
  domain   = "vpc"
  instance = aws_instance.this.id
  tags     = local.tags
}
