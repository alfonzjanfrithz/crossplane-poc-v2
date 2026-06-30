# AGENTS.md

Guide for AI agents working in this repo. Read this first.

## What this is

A **Crossplane v2** proof of concept. A namespaced composite resource (`XBucket`)
is composed into a real S3 bucket (in LocalStack) via the **v2 native per-service
AWS provider**, plus a native Secret and a terraform `Workspace`. The dynamic
bucket name round-trips through **Vault** (two independent push paths) to a
**consumer app in a separate namespace**, which reads the shared bucket.

**Fully v2-native**: namespaced XRs and MRs (`s3.aws.m.upbound.io`,
`tf.m.upbound.io`), no claims, no native P&T, no connection details, no external
secret stores, no ControllerConfig.

Runs on **kind + podman (rootless) + LocalStack** (LocalStack runs outside the
cluster, on the podman `kind` bridge network at `10.89.1.10`).

Full narrative + diagrams: `README.md` (markdown) and `index.html`
(self-contained, mermaid + highlight.js CDNs).

## Prerequisites (host)

- `podman` (rootless), `kind`, `kubectl`, `helm`
- Host inotify raised (see Trap #1):
  - `fs.inotify.max_user_instances = 8192`
  - `fs.inotify.max_user_watches = 1048576`
  - Persist at `/etc/sysctl.d/99-inotify.conf`; `sysctl --system`.

## Run

```bash
./scripts/up.sh     # 10-step bootstrap; exit 0 = success
./scripts/down.sh   # full teardown
```

`up.sh` is the source of truth. Step 0 = inotify preflight (aborts if too low).
Full bootstrap takes several minutes (provider install/family auto-resolve,
function pull, MR reconciliation, ESO sync, consumer wait).

For a **clean repeat**: `./scripts/down.sh && ./scripts/up.sh`.

`up.sh` is mostly idempotent, but after editing crossplane manifests, a
down/up is the reliable path. The script guards each step (waits for Ready,
checks value-in-Vault before installing the consumer, etc.).

## Architecture (quick)

- 3 namespaces: `demo-app` (producer), `demo-app-2` (consumer), `rss` (Vault).
- Producer chart creates an `XBucket` XR → composition renders:
  `s3.aws.m.upbound.io` Bucket + native Secret + `tf.m.upbound.io` Workspace.
- Deterministic bucket name = `prefix + XR-name + XR-uid` via
  `CombineFromComposite`; set as external-name, Secret stringData, terraform var.
- Value → Vault **two ways**: ESO `PushSecret` → `secret/crossplane/demo-app-bucket`
  (stable key), and terraform `Workspace` → `secret/crossplane-native/<bucket>`
  (dynamic key).
- Consumer (`demo-app-2`) ESO `ExternalSecret` pulls the **stable** key from Vault
  → local `shared-bucket` Secret → lists producer's objects in the shared bucket.
- Vault KV v2 at `secret/`; `vault.rss.svc.cluster.local:8200`; dev-mode root
  token `root`.
- LocalStack reached via an in-cluster headless `Service` + manual `Endpoints`.

## CRITICAL traps (non-obvious, hard-won)

If something breaks, check these first.

1. **Host inotify** must be raised *before* cluster up. Rootless podman/kind
   cannot raise it from inside the node. `provider-aws-s3` needs ~48 instances.
   `up.sh` step 0 checks and aborts if too low.
2. **`provider-aws-s3` auto-resolves `provider-family-aws`** — do NOT install the
   family provider manually (creates duplicates).
3. **family-config RBAC gap**: Crossplane's auto-RBAC omits read on
   `clusterproviderconfigs`/`providerconfigs` + CRUD on `providerconfigusages`.
   `crossplane/provider-aws-s3-rbac.yaml` grants these to a STABLE SA
   `provider-aws-s3`.
4. **Stable SA via DeploymentRuntimeConfig**
   (`crossplane/provider-aws-s3-runtime.yaml`): pin the SA through
   `serviceAccountTemplate` so the RBAC binding survives provider revisions.
   Requires `deploymentTemplate.spec.selector` + matching template labels.
5. **LocalStack endpoint** in `crossplane/provider-config.yaml`: BOTH
   `endpoint.source: Custom` AND `endpoint.services: [s3]` are required. Missing
   either → traffic silently goes to real AWS → `403 InvalidAccessKeyId`;
   LocalStack logs show NO request. (Tell: 403 with real-AWS-style
   `RequestID`/`HostID`.)
6. **Credentials**: `credentials.source: Secret` (INI format). `source: None` =
   empty creds. There is **no** `Environment` source.
7. **v2 XRD** (`crossplane/xrd.yaml`): `scope: Namespaced`, **no `claimNames`**,
   `apiextensions.crossplane.io/v2`.
8. **Do NOT set namespace in composition templates** — composed resources inherit
   the XR's namespace automatically in v2.
9. **`spec.crossplane.compositionRef`** (under `spec.crossplane.*`), NOT
   `spec.compositionRef`.
10. **Compose a native Secret** — v2 removed XR connection secrets.
11. **MR `providerConfigRef`** must include `kind: ClusterProviderConfig` (the
    default kind is `ClusterProviderConfig`, but set it explicitly).
12. **`provider-terraform` ClusterProviderConfig** needs a `kubernetes` backend,
    else terraform fails with "No state file was found".
13. **ESO `SecretStore` is namespace-scoped** → the consumer needs its own Vault
    token + SecretStore in `demo-app-2`.
14. **`function-patch-and-transform` v0.10.7**: `transform.string` needs
    `type: Format`; `combine.string` rejects `type`.
15. **ESO kinds**: `ExternalSecret` = `external-secrets.io/v1`,
    `PushSecret` = `v1alpha1`. `remoteRef` is top-level for `ExternalSecret`,
    under `match` for `PushSecret`.
16. **Never** add `extraMounts: /var/run` to the kind config (collides with the
    `/var/run → /run` symlink).
17. **HCL**: `variable` blocks must be multi-line; single-line
    `variable "x" { type=string sensitive=true }` is illegal.
18. **Docs**: mermaid captions must be alphanumeric-only (no `()` or symbols).

## File map

| Path | Purpose |
| --- | --- |
| `crossplane/xrd.yaml` | v2 namespaced `XBucket` XRD |
| `crossplane/composition.yaml` | function composition: Bucket + Secret + Workspace |
| `crossplane/provider-config.yaml` | native AWS ClusterProviderConfig (LocalStack endpoint) |
| `crossplane/provider-config-terraform.yaml` | terraform ClusterProviderConfig (k8s backend) |
| `crossplane/providers.yaml` | installs `provider-aws-s3` + `provider-terraform` |
| `crossplane/provider-aws-s3-runtime.yaml` | DeploymentRuntimeConfig (stable SA) |
| `crossplane/provider-aws-s3-rbac.yaml` | grants the stable SA the missing RBAC |
| `crossplane/aws-creds-secret.yaml` | LocalStack creds (`test`/`test`) INI Secret |
| `crossplane/localstack-service.yaml` | headless Service + Endpoints to LocalStack |
| `crossplane/function-patch-and-transform.yaml` | composition function |
| `charts/demo-app/` | producer: XBucket XR + ConfigMap + Deployment |
| `charts/demo-app-2/` | consumer: `eso.yaml` ExternalSecret + Deployment |
| `eso/pushsecret.yaml` | producer ESO: vault-token + SecretStore + PushSecret |
| `scripts/up.sh` | 10-step bootstrap |
| `scripts/down.sh` | teardown |
| `kind/config.yaml` | kind cluster config (podman) |
| `README.md` / `index.html` | full documentation (keep both in sync) |

## Conventions

- **Everything v2-native.** Namespaced MR convention uses the `.m.` infix
  (`s3.aws.m.upbound.io`). `provider-aws-s3` registers both namespaced and
  legacy cluster-scoped CRDs (~48 total).
- The **consumer reads the ESO stable key** (`crossplane/demo-app-bucket`), NOT
  the dynamic-name native key — the stable key is consumer-knowable.
- **Docs live in two places** and MUST stay in sync: `README.md` (markdown) and
  `index.html` (highlight.js github-dark + mermaid CDNs; code blocks tagged
  `language-yaml`/`language-hcl`/`language-bash`/`nohighlight`; HCL loaded via an
  extra `languages/hcl.min.js`).
- No real secrets in this repo. All creds are LocalStack fakes (`test`/`test`)
  or Vault dev-mode (`root`).

## Verify it works (proof points)

`up.sh` exits 0 and, live:

1. Producer pod is `Running` and writing objects to its bucket.
2. The bucket + objects exist in LocalStack.
3. Vault has both paths populated (`secret/crossplane/demo-app-bucket` and
   `secret/crossplane-native/<bucket>`).
4. Consumer pod (`demo-app-2`) is `Running` and logs show it listing the
   producer's objects. The consumer **will not start** until its Secret exists,
   so a `Running` consumer self-proves the entire Vault round-trip.

## Common tasks

- **Add a new composed resource**: add a managed resource to
  `composition.yaml` templates (no namespace — inherits XR ns), then down/up.
- **Change the bucket name shape**: edit the `CombineFromComposite` patch in
  `composition.yaml`; it feeds external-name, Secret stringData, and the
  terraform var together.
- **Point at real AWS**: change `endpoint` (remove `Custom`/`services`) and the
  creds in `aws-creds-secret.yaml` to real values. Everything else is unchanged.

## Commands an agent should know to run

- Lint/check: none configured (pure manifests). Validate YAML by eye or with
  `kubectl apply --dry-run=server` against the running cluster.
- Status: `kubectl get managed,composite,externalsecrets,pushsecrets -A`.
- Vault: `kubectl -n rss exec deploy/vault -- vault kv get secret/crossplane/demo-app-bucket`.
- LocalStack: `curl http://10.89.1.10:4566/_localstack/health`.
