# Talon Deploy

Deployment artifacts for **Talon Control** and **Talon Studio** — the cloud-init
bootstrap, the Helm charts, and the Terraform stacks.

Both products are self-hosted appliances: they run on your machine, in your
account, on your network. Talon Labs operates no shared infrastructure and holds
none of your detections, log samples or SIEM credentials. This repository is
everything you need to stand one up somewhere other than a laptop.

> **This repository is generated.** Every file here is copied from the product
> repositories by a single script and published to two places at once — here,
> and to `https://www.talonlabs.dev` as downloadable files. Edits made here are
> overwritten on the next publish; open an issue instead.

---

## What you actually need

You need **one** of these. They are three answers to the same question, not
three steps.

| You have | Use | Takes |
| --- | --- | --- |
| A cloud account and a credit card | **cloud-init** — paste one file into the provider's "user data" box | ~15 min |
| Terraform, and a preference for not clicking | **Terraform** — `vm/aws` or `vm/azure` | ~20 min |
| A Kubernetes cluster you already run | **Helm** — a chart from our repository | ~10 min |

If you are choosing rather than confirming, take cloud-init. Both products are
single-container appliances with a single data volume; Kubernetes buys you
nothing here except the thing your policy requires.

---

## 1. cloud-init — any VPS

Works on Hetzner, DigitalOcean, Vultr, Linode, Exoscale, OVH, Scaleway, EC2 and
Azure. All it needs is a Debian or Ubuntu image and outbound HTTPS.

```bash
curl -fsSL https://www.talonlabs.dev/control/cloud-init.yaml -o cloud-init.yaml
# or:  https://www.talonlabs.dev/studio/cloud-init.yaml
```

**Point a DNS A record at the server's IP before you boot it.** The bootstrap
gets a TLS certificate on first boot and cannot do that for a name that does not
resolve yet. On Hetzner, allocate a Primary IP first and attach it.

Replace the `__PLACEHOLDER__` values at the top, paste the file into the
provider's *user data* / *cloud-init* field, and create the server. Leave a
placeholder in and the machine stops with a message naming it rather than coming
up half-configured.

Roughly ten minutes later you have Docker, a firewall denying everything except
SSH/80/443, Caddy terminating TLS with a real certificate, and the appliance
behind it. Watch it with `ssh talon@<ip> 'sudo tail -f /var/log/talon-install.log'`.

Then take the encryption key off the box and put it in your password manager:

```bash
ssh talon@<ip> 'sudo cat /root/talon-credentials.txt'
```

It encrypts every credential the appliance stores. **A restored volume without it
is ciphertext.** This is the step people skip and regret.

## 2. Terraform

Each stack is self-contained and takes an HTTP archive as a module source, so
there is nothing to clone:

```hcl
module "talon" {
  source = "https://www.talonlabs.dev/control/terraform/vm-aws.tar.gz"

  domain         = "control.example.com"
  admin_email    = "you@example.com"
  ssh_public_key = file("~/.ssh/id_ed25519.pub")
  image_tag      = "v1.0.0-beta.1"
}
```

Available as `vm-aws`, `vm-azure`, `kubernetes-aws`, `kubernetes-azure`, for
`control` and for `studio`. The sources are in this repository under
`control/terraform/` and `studio/terraform/` if you would rather read them first
— you should.

The VM stacks fetch the same cloud-init as the manual path above, so the two
cannot drift. Set `cloud_init_file` to a local copy to pin it, or to apply
without egress to `talonlabs.dev`.

The Kubernetes stacks create the cluster, a managed Postgres, and the Helm
release together. If you already have a cluster, skip them and use the chart
directly.

## 3. Helm

A plain HTTP chart repository — no registry, no login:

```bash
helm repo add talon https://www.talonlabs.dev/charts
helm repo update
helm search repo talon
```

```bash
helm install control talon/talon-control \
  --namespace talon --create-namespace \
  --set ingress.host=control.example.com \
  --set secrets.authSecret="$(openssl rand -hex 32)" \
  --set secrets.nextauthSecret="$(openssl rand -hex 32)" \
  --set secrets.encryptionKey="$(openssl rand -hex 32)" \
  --set postgres.password="$(openssl rand -hex 24)"
```

Chart sources are under `charts/` here. Read `values.yaml` before a real
install; `values-production.yaml` is the starting point for one.

**The chart refuses to render above one replica**, deliberately. The login and
MFA throttles count in-process with no shared store, scheduled automations
double-fire, the event bus is per-process, and the data volume is
ReadWriteOnce. Two replicas is not a scaled appliance, it is a broken one — so
scale the node, not the deployment.

---

## Before any of the above: the image registry

**The container images are not anonymously pullable today** (checked
2026-09-16). `ghcr.io/talon-labs-detection-platform/talon-control` and
`…/talon-studio` both answer `401` to an unauthenticated request, because the
packages are private while the products are in beta.

So every path on this page needs the machine to authenticate first:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USERNAME" --password-stdin
```

A classic PAT with `read:packages` is enough. On Kubernetes the cluster needs it
as an `imagePullSecret` rather than a shell login; the chart takes
`image.pullSecrets`.

This is a packaging state, not a design. When the packages go public this
section goes away and nothing else changes — the cloud-init, the charts and the
Terraform are already anonymous.

---

## Where everything is served

Nothing here requires a GitHub account. Every file in this repository is also a
plain download:

| | URL |
| --- | --- |
| Bootstrap | `https://www.talonlabs.dev/control/cloud-init.yaml` |
| | `https://www.talonlabs.dev/studio/cloud-init.yaml` |
| Helm repository | `https://www.talonlabs.dev/charts` |
| Terraform modules | `https://www.talonlabs.dev/control/terraform/<shape>.tar.gz` |
| | `https://www.talonlabs.dev/studio/terraform/<shape>.tar.gz` |
| Compose install | `https://www.talonlabs.dev/control/docker-compose.yml` |
| Checksums | `https://www.talonlabs.dev/deploy-manifest.json` |

`deploy-manifest.json` carries a SHA-256 for every published file, so you can
check that what you downloaded is what we published.

## Documentation

- Choosing between the options: <https://www.talonlabs.dev/deploy>
- Talon Control, in full: <https://www.talonlabs.dev/control/docs/install>
- Talon Studio: the manual is not public yet — the product is in private beta.
  <https://www.talonlabs.dev/deploy> carries the hosting story, and the files in
  `studio/` here carry their own comments.

## Licence and support

These deployment artifacts are provided for use with a licensed Talon Control or
Talon Studio deployment. The product images themselves are separately licensed.
Issues with the artifacts in this repository are welcome here; product support
goes through your normal channel.
