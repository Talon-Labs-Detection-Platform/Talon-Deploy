# Talon Control — Helm chart

Runs the Control console on Kubernetes: one app pod, one data volume, and
either a bundled Postgres or your own.

**Docker Compose is still the reference deployment.** `docker-compose.prod.yml`
is what the runbook in [`docs/production-hosting.md`](../../docs/production-hosting.md)
describes, what the auto-updater promotes, and what most self-hosters should
run. Use this chart when you already operate a cluster and want Control in it —
not as an upgrade over a single VM, which it is not.

## Scope

The console and its database. That is the whole chart, deliberately.

The optional sidecars — SearXNG web search, the Kokoro speech engine, the Vexa
meeting gateway, the voice-cloning engine — are Docker Compose profiles, and
this chart renders none of them. The chart this one succeeds carried all four
across 3,031 lines, drifted against compose in exactly those stacks, and was
retired on 2026-09-13 for that reason. On Kubernetes, run a sidecar as its own
release and point the app at it with `extraEnv`:

```yaml
extraEnv:
  - name: TALON_CONTROL_SEARXNG_URL
    value: http://searxng.searxng.svc.cluster.local:8080
```

`test/unit/helm-chart.test.ts` fails if a template starts reading
`.Values.kokoro` and friends again, so putting a stack back is a decision
someone reviews rather than a file someone adds.

## Install

```bash
helm install talon-control ./helm/talon-control \
  --set secrets.authSecret="$(openssl rand -hex 32)" \
  --set secrets.encryptionKey="$(openssl rand -hex 32)" \
  --set postgres.password="$(openssl rand -hex 24)" \
  --set secrets.adminEmail=you@example.com \
  --set secrets.adminPassword='<a real password>'
```

Then reach it:

```bash
kubectl port-forward svc/talon-control-talon-control 3001:3001
```

**Escrow `secrets.encryptionKey` in your password manager before first boot.**
It encrypts every stored credential — AI keys, the GitHub App key, SMTP,
licence keys. Lose it and a restored database does not help you: what is in it
is ciphertext.

## Production

```bash
helm install talon-control ./helm/talon-control \
  -f helm/talon-control/values-production.yaml \
  --set secrets.existingSecret=talon-control-secrets \
  --set ingress.host=control.example.com \
  --set config.nextauthUrl=https://control.example.com
```

`values-production.yaml` supplies no secrets and no defaults that could become
one: credentials come from a Secret you created, and Postgres is external. See
the comments in that file for what the Secret must contain.

## Two things that bite

**One replica, enforced.** The chart refuses to render above `replicaCount: 1`.
Control keeps correctness-critical state in the process — in-memory rate-limit
counters, an in-process SSE/run bus, schedule-triggered automations with no
cross-process guard, boot-time migrations with no advisory lock, and a
ReadWriteOnce data volume. Backing the rate limiter with Redis fixes one of
those five. `replicaCount: 0` still renders, so scaling to zero for maintenance
works.

**`/app/data` ownership.** The image runs as uid 1000 with no root left to
chown a fresh volume, and `podSecurityContext.fsGroup` is silently ignored by
every hostPath-backed provisioner (kubelet only applies it to volume plugins
that report themselves ownership-managed). The `fix-data-ownership` init
container is what makes the guarantee hold there. Both are on by default; turn
off `persistence.fixOwnership` only where a Pod Security Standard forbids the
root init container, and chown the volume yourself if you do.

## Values

Every key is commented in [`values.yaml`](values.yaml). The ones worth knowing
before a first install:

| Key | Default | Why you would change it |
| --- | --- | --- |
| `postgres.bundled` | `true` | `false` for a managed database — a bundled StatefulSet on one node has no backups, no PITR and no failover |
| `postgres.password` | *(required)* | No default, on purpose: it used to be `talon`, and every connection URL took it silently |
| `persistence.storage` | `20Gi` | Dev-session checkouts and the media library live here |
| `persistence.existingClaim` | `""` | Point at a claim you made yourself for anything holding real data — it then has no lifecycle relationship to the release |
| `config.trustProxy` | `false` | `true` behind an ingress, or per-IP rate limiting collapses to one bucket for the whole internet |
| `config.nextauthUrl` | *(localhost)* | Must match what the ingress serves, scheme included, or sign-in loops |
| `signing.enabled` | `false` | `true` only on the instance that mints Talon Studio licence keys |
| `devSessions.oauthToken` | `""` | From `claude setup-token`; without it Dev Sessions load and every session fails on its first turn |
