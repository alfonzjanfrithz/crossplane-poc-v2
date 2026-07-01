#!/usr/bin/env bash
# Bootstraps the v2-native Crossplane PoC from scratch (idempotent).
# Usage: ./scripts/up.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KIND_EXPERIMENTAL_PROVIDER=podman

echo "==> 0/10  preflight: inotify check"
INST=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
if [ "$INST" -lt 512 ]; then
  echo "WARNING: fs.inotify.max_user_instances=$INST is too low for the upjet"
  echo "         v2 AWS provider (needs ~48 instances for its S3 CRDs). It will"
  echo "         crashloop with 'too many open files'. Raise it on the HOST:"
  echo "           sudo sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=1048576"
  echo "         (persist: write both to /etc/sysctl.d/99-inotify.conf)"
fi

echo "==> 1/10  MiniStack (podman, kind network)"
if ! podman ps --format '{{.Names}}' | grep -q '^ministack$'; then
  podman rm -f ministack >/dev/null 2>&1 || true
  # No static --ip: let podman assign one from the kind network's subnet
  # (the subnet differs per machine). We read the assigned IP back below and
  # inject it into the manual Endpoints, so nothing is hardcoded.
  podman run -d --name ministack --network kind \
    -p 4566:4566 docker.io/ministackorg/ministack:latest >/dev/null
fi
# Discover the IP podman gave MiniStack on the kind network (runs whether we
# just started it or it was already up). This value flows into step 4.
MS_IP=$(podman inspect ministack -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}')
echo "      MiniStack IP on kind network: $MS_IP"

echo "==> 2/10  kind cluster"
kind get clusters 2>/dev/null | grep -q '^crossplane-poc$' || \
  kind create cluster --config "$ROOT/kind/config.yaml" --wait 60s

# Corporate TLS interception: the proxy re-signs HTTPS with an internal CA that
# the kind node's containerd does not trust, so image pulls fail with
# "x509: certificate signed by unknown authority". Tell containerd to skip TLS
# verification per registry. kind already sets config_path=/etc/containerd/certs.d,
# and hosts.toml is read per-pull, so no containerd restart is needed.
echo "      configuring containerd to skip TLS verify for image registries"
NODE=crossplane-poc-control-plane
for reg in xpkg.crossplane.io xpkg.upbound.io ghcr.io quay.io docker.io registry-1.docker.io; do
  server="https://$reg"; [ "$reg" = "docker.io" ] && server="https://registry-1.docker.io"
  podman exec "$NODE" mkdir -p "/etc/containerd/certs.d/$reg"
  podman exec "$NODE" sh -c "cat > /etc/containerd/certs.d/$reg/hosts.toml <<EOF
server = \"$server\"

[host.\"$server\"]
  capabilities = [\"pull\", \"resolve\"]
  skip_verify = true
EOF"
done
# Clear any pods stuck in ImagePullBackOff from an earlier TLS-failed run so they
# re-pull immediately instead of waiting out the kubelet backoff (no-op if none).
kubectl -n crossplane-system delete pods --all --ignore-not-found >/dev/null 2>&1 || true

echo "==> 3/10  helm repos + platform charts"
helm repo add crossplane-stable  https://charts.crossplane.io/stable/  --force-update >/dev/null
helm repo add hashicorp          https://helm.releases.hashicorp.com   --force-update >/dev/null
helm repo add external-secrets   https://charts.external-secrets.io    --force-update >/dev/null
helm repo update >/dev/null

# Crossplane's package manager fetches package descriptors over HTTPS from inside
# the core pod (NOT via containerd, so the certs.d skip_verify above does not help
# it). Behind a TLS-intercepting proxy that fails with "x509: certificate signed by
# unknown authority". Crossplane has no skip-TLS flag, so feed it the host's trusted
# CA bundle (which includes the proxy's CA) via registryCaBundleConfig. The bundle is
# extracted from the host's trust store at runtime into an ephemeral ConfigMap; it is
# never committed. On a machine without a proxy this is a harmless extra trust bundle.
kubectl get namespace crossplane-system >/dev/null 2>&1 || kubectl create namespace crossplane-system >/dev/null
CA_BUNDLE="$(mktemp)"
if command -v security >/dev/null 2>&1; then
  # macOS: export the SystemRoot + System keychains to PEM.
  security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain >  "$CA_BUNDLE" 2>/dev/null || true
  security find-certificate -a -p /Library/Keychains/System.keychain                         >> "$CA_BUNDLE" 2>/dev/null || true
else
  # Linux: copy the system trust bundle (Debian/Ubuntu and Fedora/RHEL paths).
  for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
    [ -s "$f" ] && cp "$f" "$CA_BUNDLE" && break
  done
fi
[ -s "$CA_BUNDLE" ] || { echo "ERROR: no CA bundle found on host; cannot start Crossplane." >&2; rm -f "$CA_BUNDLE"; exit 1; }
# Use create (not apply): the bundle is too big for apply's last-applied-config
# annotation (256KB cap); ConfigMap data allows ~1MB. Delete-first keeps it idempotent.
kubectl -n crossplane-system delete configmap registry-ca --ignore-not-found >/dev/null
kubectl -n crossplane-system create configmap registry-ca --from-file=ca-bundle.crt="$CA_BUNDLE" >/dev/null
rm -f "$CA_BUNDLE"

helm upgrade --install crossplane crossplane-stable/crossplane \
  -n crossplane-system --create-namespace \
  --set registryCaBundleConfig.name=registry-ca \
  --set registryCaBundleConfig.key=ca-bundle.crt --wait >/dev/null
helm upgrade --install vault hashicorp/vault -n rss --create-namespace \
  --set server.dev.enabled=true --set server.dev.devRootToken=root \
  --set injector.enabled=false --wait >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --set installCRDs=true --wait >/dev/null

echo "==> 4/10  MiniStack in-cluster Service (manual Endpoints)"
# Inject the discovered MiniStack IP into the Endpoints placeholder at apply
# time, so the in-cluster DNS name routes to wherever podman put the container.
sed "s/__MINISTACK_IP__/$MS_IP/" "$ROOT/crossplane/ministack-service.yaml" \
  | kubectl apply --server-side -f - >/dev/null

echo "==> 5/10  Crossplane function"
kubectl apply -f "$ROOT/crossplane/function-patch-and-transform.yaml" >/dev/null

echo "==> 6/10  providers (v2): runtime config -> provider-aws-s3"
# DeploymentRuntimeConfig must exist before the provider reconciles so the
# revision is created with the stable ServiceAccount (provider-aws-s3).
kubectl apply -f "$ROOT/crossplane/provider-aws-s3-runtime.yaml" >/dev/null
kubectl apply -f "$ROOT/crossplane/providers.yaml" >/dev/null
# Let Crossplane's composite controller manage the composed ESO PushSecret
# (the Vault sync). Aggregated ClusterRole, so it must exist before the XR.
kubectl apply -f "$ROOT/crossplane/eso-pushsecret-rbac.yaml" >/dev/null

# Wait for the stable SA to exist, then bind the family-config RBAC. The
# per-service provider must read the family's ClusterProviderConfig /
# ProviderConfigUsage CRDs, which its auto-RBAC omits.
echo "      waiting for stable SA provider-aws-s3..."
for i in $(seq 1 30); do
  kubectl -n crossplane-system get sa provider-aws-s3 >/dev/null 2>&1 && break
  sleep 2
done
kubectl apply -f "$ROOT/crossplane/provider-aws-s3-rbac.yaml" >/dev/null

echo "      waiting for function + providers healthy..."
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Healthy")].status}=True' \
  functions.pkg.crossplane.io/function-patch-and-transform \
  providers.pkg.crossplane.io/provider-aws-s3 \
  --timeout=420s >/dev/null

echo "==> 7/10  ProviderConfigs + XRD + Composition"
kubectl apply -f "$ROOT/crossplane/aws-creds-secret.yaml" >/dev/null
kubectl apply -f "$ROOT/crossplane/provider-config.yaml" >/dev/null
kubectl apply -f "$ROOT/crossplane/xrd.yaml" >/dev/null
kubectl apply -f "$ROOT/crossplane/composition.yaml" >/dev/null

echo "==> 8/10  demo app (Helm: XBucket XR + ConfigMap + Deployment)"
helm upgrade --install demo-app "$ROOT/charts/demo-app" -n demo-app --create-namespace >/dev/null

echo "      waiting for XBucket demo-app to become Ready..."
kubectl -n demo-app wait xbucket/demo-app --for=condition=Ready --timeout=300s >/dev/null

echo "==> 9/10  Vault sync: composed ESO PushSecret writes crossplane/demo-app-bucket"
echo "       waiting for the composed PushSecret to land the value in Vault..."
for i in $(seq 1 30); do
  v=$(kubectl -n rss exec vault-0 -- vault kv get -field=bucketName secret/crossplane/demo-app-bucket 2>/dev/null || true)
  [ -n "$v" ] && break
  sleep 2
done

echo "==> 10/10 demo-app-2 consumer (reads shared bucket from Vault via ExternalSecret)"
helm upgrade --install demo-app-2 "$ROOT/charts/demo-app-2" -n demo-app-2 --create-namespace >/dev/null
# Pod readiness transitively proves: ExternalSecret synced <- Vault had value <-
# composed Workspace <- Crossplane bucket.
kubectl -n demo-app-2 wait deploy/demo-app-2 --for=condition=Available --timeout=180s >/dev/null

echo
echo "============================================================"
echo " PROVISIONED INVENTORY  (everything that just got created)"
echo "============================================================"

echo
echo "-- Crossplane platform (cluster-scoped) --------------------"
kubectl get providers.pkg.crossplane.io,functions.pkg.crossplane.io 2>/dev/null || true
kubectl get xrd,compositions 2>/dev/null || true
kubectl get clusterproviderconfigs.aws.m.upbound.io 2>/dev/null || true

echo
echo "-- crossplane-system (controllers) -------------------------"
kubectl -n crossplane-system get pods 2>/dev/null || true

echo
echo "-- demo-app  (PRODUCER namespace) --------------------------"
echo "   XR -> composed Bucket + Secret + PushSecret, plus the producer app + its SecretStore"
kubectl -n demo-app get xbucket,bucket.s3.aws.m.upbound.io,pushsecret,secretstore,secret,deploy,pods 2>/dev/null || true

echo
echo "-- demo-app-2  (CONSUMER namespace) ------------------------"
echo "   ExternalSecret pulls the value from Vault into a local Secret the app reads"
kubectl -n demo-app-2 get externalsecret,secretstore,secret,deploy,pods 2>/dev/null || true

echo
echo "-- rss  (Vault) --------------------------------------------"
kubectl -n rss get pods 2>/dev/null || true
echo "   value the composed PushSecret wrote (secret/crossplane/demo-app-bucket):"
kubectl -n rss exec vault-0 -- vault kv get secret/crossplane/demo-app-bucket 2>/dev/null || echo "     (not present yet)"

echo
echo "-- ministack-system  (in-cluster route to MiniStack) -----"
kubectl -n ministack-system get svc,endpoints 2>/dev/null || true
echo "   buckets in MiniStack:"
podman exec ministack awslocal s3api list-buckets 2>/dev/null || true

echo
echo "============================================================"
echo " WHERE TO LOOK NEXT  (copy/paste)"
echo "============================================================"
echo "  kubectl -n demo-app logs deploy/demo-app                                       # producer writing the dynamic bucket"
echo "  kubectl -n demo-app-2 logs deploy/demo-app-2                                    # consumer reading it back from Vault"
echo "  kubectl -n demo-app describe xbucket demo-app                                   # the XR + its composed resourceRefs"
echo "  kubectl -n demo-app get pushsecret -o wide                                      # producer -> Vault (PushSecret), Ready=True"
echo "  kubectl -n demo-app-2 get externalsecret,secret                                 # Vault -> local Secret (ExternalSecret)"
echo "  kubectl -n rss exec vault-0 -- vault kv get secret/crossplane/demo-app-bucket   # the shared value in Vault"
echo "  podman exec ministack awslocal s3api list-buckets                              # the shared bucket"
echo "  ./scripts/down.sh                                                               # teardown"
