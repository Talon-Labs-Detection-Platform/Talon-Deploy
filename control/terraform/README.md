# Talon Control — self-hosting Terraform

Stands up **your own** Talon Control instance in **your own** cloud account.
Talon Labs never touches it: no shared infrastructure, no phone-home beyond the
optional licence refresh, no access to your data.

> **Status: written ahead of first apply.** Structure and resource choices are
> deliberate and cross-checked against the provider schemas, but no stack here
> has been applied against a live account — there were no cloud credentials in
> the environment where it was written. Expect first-apply fixes (provider
> version pins, an AMI filter that has moved on, a quota you have not raised).
> Apply one stack, fix forward, then move on. Nothing here touches the app
> codebase, so a failed apply costs you nothing but time.

> **The registry is private today.** Checked 2026-09-15: the image answers
> `401` to an unauthenticated request and no release tags exist yet. The `vm/`
> stacks therefore need a `docker login ghcr.io` on the box (the bootstrap does
> not carry a token, deliberately), and the `kubernetes/` stacks need an
> `imagePullSecret` in the namespace. See
> [docs/cloud-hosting.md](../../../docs/cloud-hosting.md). When the package
> goes public this stops being a step.

## Which stack

| You have | Use | Runs |
| --- | --- | --- |
| Nothing, and want the cheapest thing that works | `vm/` | One VM, Docker Compose, Caddy for TLS |
| A Kubernetes cluster already, or a policy that says workloads run in one | `kubernetes/` | The published `talon-control` chart on a new EKS/AKS cluster with managed Postgres |

**Most people want `vm/`.** Control is a single-writer appliance — one process,
one volume, one database — so a cluster buys you node repair and little else,
at roughly ten times the monthly cost. `kubernetes/` exists because some
organisations cannot run a VM, not because it is the better shape.

If you want cheaper still and do not need Terraform at all: create a €4/month
Hetzner CX22 by hand and paste [`deploy/cloud-init.yaml`](../../../deploy/cloud-init.yaml)
into the user-data box. That is the same machine this VM stack builds, without
the state file. See [docs/cloud-hosting.md](../../../docs/cloud-hosting.md).

## Layout

```text
vm/
  aws/          EC2 + EBS + security group + Elastic IP, bootstrapped by cloud-init
  azure/        Linux VM + managed disk + NSG + static public IP, same cloud-init
kubernetes/
  aws/          EKS + RDS Postgres + the Helm release
  azure/        AKS + Postgres Flexible Server + the Helm release
```

Both `vm/` stacks read the **same** bootstrap the hand-install path uses,
substituting the `__PLACEHOLDER__` tokens with `replace()`. They FETCH it —
`var.cloud_init_url`, defaulting to the published copy — rather than reading
`../../../../../deploy/cloud-init.yaml`, which is what they did until
2026-09-16. That relative path resolved inside a checkout of this repo and
nowhere else: published as a module archive, or read from a public mirror,
those `../` walk off into the caller's filesystem and the plan fails on a
missing file. Set `var.cloud_init_file` to a local copy to pin the bootstrap,
or to apply without egress. There is one bootstrap to keep correct, not one per
provider — and a fix to the hand-install path is automatically a fix to both
Terraform stacks.

Both `kubernetes/` stacks install the **published chart** rather than a path
into this repository. `var.chart_repository` defaults to
`https://www.talonlabs.dev/charts`, which is a plain HTTPS Helm repository — an
index and a tarball, no registry and no credentials — and `var.chart_version`
pins which one. They read `${path.module}/../../../../../helm/talon-control`
until 2026-09-16, with the same problem the bootstrap had: it resolved only
inside a checkout of a private repo.


### Verify before you apply

The bootstrap becomes user-data and runs as root on first boot, and on this path
there is no human in the loop to read it first. Every published file carries a
SHA-256 in <https://www.talonlabs.dev/deploy-manifest.json>:

```bash
curl -fsSL https://www.talonlabs.dev/control/cloud-init.yaml | sha256sum
```

Set `cloud_init_sha256` to that value and the plan fails if what comes back is
not what you reviewed. Left empty, the plan takes whatever the URL serves —
which is HTTPS-authenticated but not pinned. Set it for anything you would call
production, and re-read the bootstrap before you move the pin.

## Before you apply, either way

1. **A DNS record.** Point an A record at the address the stack outputs before
   you apply, or on first boot Caddy cannot complete the HTTP-01 challenge and
   you get no certificate. The VM stacks allocate a static address first for
   exactly this reason — `terraform apply -target` the address, set the DNS,
   then apply the rest.
2. **Escrow the encryption key.** The bootstrap generates
   `TALON_CONTROL_ENCRYPTION_KEY` on the box and writes it to
   `/root/talon-credentials.txt`. It encrypts every credential the console
   stores. Copy it into your password manager on day one: a restored database
   without it is ciphertext.
3. **Budget alerts.** Both clouds will happily bill you for a cluster you
   forgot. Set a monthly budget alert before the first apply, not after the
   first invoice.

## State

Every stack defaults to local state, which is right for one person running one
instance. Put it in a bucket before a second person touches it — a `terraform
destroy` from a stale local state file is how a database disappears.
