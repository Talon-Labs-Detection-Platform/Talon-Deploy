# Talon Studio — self-hosting Terraform

Stands up **your own** Talon Studio appliance in **your own** cloud account.
Talon Labs never touches it: no shared infrastructure, no access to your
detections, your log samples or your SIEM credentials.

> **Not to be confused with [`../`](../README.md)** — the stacks one level up
> (`accounts/`, `fleet/`, `platform/`, `tenants/`) build Talon Labs' *own*
> multi-tenant hosted fleet. They are not for customers and will create an AWS
> Organization if you apply them. Everything you want is in this directory.

> **Status: written ahead of first apply.** Structure and resource choices are
> deliberate and cross-checked against the provider schemas and the chart's own
> values, but no stack here has been applied against a live account — there were
> no cloud credentials in the environment where it was written. Expect
> first-apply fixes (provider version pins, an AMI filter that has moved on, a
> quota you have not raised). Apply one stack, fix forward, then move on.

> **The registry is private today.** Checked 2026-09-15: the appliance image
> answers `401` and the OCI chart `403` to an unauthenticated request, and no
> release tags exist yet. The `vm/` stacks therefore need a `docker login
> ghcr.io` on the box (the bootstrap does not carry a token, deliberately), and
> the `kubernetes/` stacks need both a `helm registry login` for the provider to
> fetch the chart and an `imagePullSecret` in the namespace for the pod to pull
> the image. See [cloud-hosting.md](../../../docs/operators/cloud-hosting.md).
> When the packages go public this stops being a step.

## Which stack

| You have | Use | Runs |
| --- | --- | --- |
| Nothing, and want the cheapest thing that works | `vm/` | One VM, the appliance image, Caddy for TLS |
| A Kubernetes cluster already, or a policy that says workloads run in one | `kubernetes/` | The published `talon-studio` chart on a new EKS/AKS cluster with managed Postgres |

**Most people want `vm/`.** Studio ships as a single appliance container — the
Next.js app, an embedded Postgres and the embedded pySigma service on one
`/data` volume. That is one process on one disk, so a cluster buys node repair
and little else, at roughly ten times the monthly cost.

If you want cheaper still and do not need Terraform at all: create a €4/month
Hetzner CX22 by hand and paste [`deploy/cloud-init.yaml`](../../../deploy/cloud-init.yaml)
into the user-data box. That is the same machine the VM stack builds, without
the state file. See [docs/operators/cloud-hosting.md](../../../docs/operators/cloud-hosting.md).

## Layout

```text
vm/
  aws/          EC2 + EBS + security group + Elastic IP, bootstrapped by cloud-init
  azure/        Linux VM + managed disk + NSG + static public IP, same cloud-init
kubernetes/
  aws/          EKS + RDS Postgres + the published chart
  azure/        AKS + Postgres Flexible Server + the published chart
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
provider.

Both `kubernetes/` stacks install the **published chart** rather than the copy
in `helm/`, pinned with `chart_version`. `var.chart_repository` defaults to
`https://www.talonlabs.dev/charts`, which is a plain HTTPS Helm repository —
an index and a tarball, no registry and no credentials. It pointed at
`oci://ghcr.io/talon-labs-detection-platform/charts` until 2026-09-16, which
answers 403 to anyone outside the organisation because the package is private,
so every customer apply failed at the pull.


### Verify before you apply

The bootstrap becomes user-data and runs as root on first boot, and on this path
there is no human in the loop to read it first. Every published file carries a
SHA-256 in <https://www.talonlabs.dev/deploy-manifest.json>:

```bash
curl -fsSL https://www.talonlabs.dev/studio/cloud-init.yaml | sha256sum
```

Set `cloud_init_sha256` to that value and the plan fails if what comes back is
not what you reviewed. Left empty, the plan takes whatever the URL serves —
which is HTTPS-authenticated but not pinned. Set it for anything you would call
production, and re-read the bootstrap before you move the pin.

## Before you apply, either way

1. **A DNS record.** Point a record at the address the stack outputs before you
   apply, or on first boot Caddy cannot complete the HTTP-01 challenge and you
   get no certificate. The VM stacks allocate a static address first for exactly
   this reason — `terraform apply -target` the address, set the DNS, then apply
   the rest.
2. **Escrow the encryption key.** It encrypts every credential the appliance
   stores: SIEM connections, API keys, git tokens. The VM stacks generate it on
   the box and write it to `/root/talon-credentials.txt`; the Kubernetes stacks
   surface it as a sensitive output. Copy it into your password manager on day
   one — a restored `/data` volume without it is ciphertext.
3. **First boot is slow.** The appliance initialises Postgres and syncs
   detection content on its first start. Ten minutes is normal; the Kubernetes
   stacks allow thirty before they give up.
4. **Budget alerts.** Both clouds will happily bill you for a cluster you
   forgot. Set a monthly budget alert before the first apply.

## State

Every stack defaults to local state, which is right for one person running one
instance. Put it in a bucket before a second person touches it — a `terraform
destroy` from a stale local state file is how a database disappears. The
Kubernetes stacks put the encryption key in state, which makes that state as
sensitive as the appliance itself: encrypt the backend, restrict who can read it.
