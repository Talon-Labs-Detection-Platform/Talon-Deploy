# Talon Control on EKS, with RDS Postgres, installed from the chart in
# helm/talon-control.
#
# Read cloud/terraform/self-host/README.md before choosing this over ../../vm/aws.
# Control is a single-writer appliance — one process, one volume, one database —
# so a cluster buys node repair and little else, at roughly ten times the
# monthly cost. This exists for organisations whose policy is "workloads run in
# Kubernetes", which is a real constraint and not a technical one.

locals {
  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Component = "talon-control"
  })
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.name}-vpc"
  cidr = "10.43.0.0/16"

  azs = var.availability_zones
  # RDS wants a subnet group spanning two AZs even for a single-AZ instance.
  private_subnets = ["10.43.1.0/24", "10.43.2.0/24"]
  public_subnets  = ["10.43.101.0/24", "10.43.102.0/24"]

  # One NAT gateway, not one per AZ: the app pod needs outbound HTTPS (image
  # pulls, AI providers, GitHub) and nothing here is highly available anyway,
  # so paying for a second is paying for symmetry.
  enable_nat_gateway = true
  single_nat_gateway = true
  enable_dns_hostnames = true

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.33"

  cluster_name    = var.name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Auto Mode: AWS manages Karpenter, node patching, the VPC CNI, the load
  # balancer controller and EBS CSI as off-cluster components. For one
  # single-replica workload that is the whole point — there is no fleet here to
  # justify running that machinery yourself.
  cluster_compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.admin_cidrs

  # Whoever runs `terraform apply` gets cluster-admin, otherwise the very next
  # step — installing the chart — fails with an authorisation error that reads
  # like a bug in the chart.
  enable_cluster_creator_admin_permissions = true

  tags = local.tags
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = module.vpc.private_subnets
  tags       = local.tags
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db-sg"
  description = "Postgres, reachable only from inside the VPC"
  vpc_id      = module.vpc.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "db" {
  security_group_id = aws_security_group.db.id
  description       = "Postgres from the cluster's private subnets"
  cidr_ipv4         = module.vpc.vpc_cidr_block
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

resource "random_password" "db" {
  length = 32
  # RDS rejects '/', '@', '"' and space in a master password, and a URL-unsafe
  # character here would break the connection string the chart assembles.
  override_special = "_-"
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-db"
  engine         = "postgres"
  engine_version = var.postgres_version
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_encrypted     = true
  storage_type          = "gp3"

  db_name  = "talon_control"
  username = "talon"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period = var.backup_retention_days
  skip_final_snapshot     = false
  final_snapshot_identifier = "${var.name}-db-final"
  deletion_protection       = true

  tags = local.tags
}

# The secrets the chart would otherwise render from values. Kept in a Secret
# this stack owns so nothing credential-shaped lands in `helm get values`, and
# so the chart's own `secrets.existingSecret` path is the one in use.
resource "random_password" "auth_secret" {
  length  = 64
  special = false
}

resource "random_password" "encryption_key" {
  length  = 64
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
    AUTH_SECRET = random_password.auth_secret.result
    # WARNING: this lands in Terraform state, which is therefore as sensitive as
    # the database itself — encrypt the backend and restrict who can read it.
    # It decrypts every credential the console stores; losing it makes a
    # restored database ciphertext, so copy it into your password manager too.
    TALON_CONTROL_ENCRYPTION_KEY = random_password.encryption_key.result
    TALON_CONTROL_POSTGRES_URL = format(
      "postgresql://talon:%s@%s/talon_control",
      urlencode(random_password.db.result),
      aws_db_instance.this.endpoint,
    )
    TALON_CONTROL_ADMIN_EMAIL    = var.admin_email
    TALON_CONTROL_ADMIN_PASSWORD = random_password.admin.result
  }

  type = "Opaque"
}

resource "helm_release" "talon_control" {
  name      = var.name
  namespace = kubernetes_namespace_v1.this.metadata[0].name

  # The published chart, not a path into this repository. The path resolved
  # only inside a checkout of a private repo — from a module archive or the
  # public talon-deploy repository it walked off into the caller's filesystem.
  #
  # A Helm repository is an index.yaml and a tarball served over HTTPS — no
  # registry, no login, nothing to authorise. `helm repo add talon
  # https://www.talonlabs.dev/charts` is the same thing by hand.
  repository = var.chart_repository
  chart      = "talon-control"
  version    = var.chart_version

  # Migrations run on boot and the data volume is ReadWriteOnce, so let the pod
  # finish before reporting success — otherwise a failed first boot looks like a
  # successful apply.
  wait    = true
  timeout = 900

  values = [yamlencode({
    image = { tag = var.image_tag }
    # The chart refuses to render above 1 anyway; stating it keeps the reason
    # visible from here rather than only in the chart.
    replicaCount = 1
    secrets      = { existingSecret = kubernetes_secret_v1.this.metadata[0].name }
    postgres     = { bundled = false }
    persistence  = { enabled = true, storage = "${var.disk_size_gb}Gi" }
    config = {
      nextauthUrl = "https://${var.domain}"
      # Every request arrives through the ingress, so without this per-IP rate
      # limiting collapses to one bucket for the whole internet.
      trustProxy = true
      logFormat  = "json"
    }
    ingress = {
      enabled   = true
      className = var.ingress_class
      host      = var.domain
      tls       = var.tls_secret_name != ""
      tlsSecretName = var.tls_secret_name
      annotations = {
        # Dev-session output and the SSE run bus stream; a proxy that buffers
        # them turns a live workboard into one that updates in bursts.
        "nginx.ingress.kubernetes.io/proxy-buffering"   = "off"
        "nginx.ingress.kubernetes.io/proxy-read-timeout" = "3600"
      }
    }
  })]

  depends_on = [aws_db_instance.this]
}
