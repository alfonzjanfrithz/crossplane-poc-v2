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

echo "==> 1/10  LocalStack (podman, kind network)"
if ! podman ps --format '{{.Names}}' | grep -q '^localstack$'; then
  podman rm -f localstack >/dev/null 2>&1 || true
  # No static --ip: let podman assign one from the kind network's subnet
  # (the subnet differs per machine). We read the assigned IP back below and
  # inject it into the manual Endpoints, so nothing is hardcoded.
  podman run -d --name localstack --network kind \
    -p 4566:4566 docker.io/localstack/localstack:4.3 >/dev/null
fi
# Discover the IP podman gave LocalStack on the kind network (runs whether we
# just started it or it was already up). This value flows into step 4.
LS_IP=$(podman inspect localstack -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}')
echo "      LocalStack IP on kind network: $LS_IP"

echo "==> 2/10  kind cluster"
kind get clusters 2>/dev/null | grep -q '^crossplane-poc$' || \
  kind create cluster --config "$ROOT/kind/config.yaml" --wait 60s

echo "==> 3/10  helm repos + platform charts"
helm repo add crossplane-stable  https://charts.crossplane.io/stable/  >/dev/null
helm repo add hashicorp          https://helm.releases.hashicorp.com   >/dev/null
helm repo add external-secrets   https://charts.external-secrets.io    >/dev/null
helm repo update >/dev/null
helm upgrade --install crossplane crossplane-stable/crossplane \
  -n crossplane-system --create-namespace --wait >/dev/null
helm upgrade --install vault hashicorp/vault -n rss --create-namespace \
  --set server.dev.enabled=true --set server.dev.devRootToken=root \
  --set injector.enabled=false --wait >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --set installCRDs=true --wait >/dev/null

echo "==> 4/10  LocalStack in-cluster Service (manual Endpoints)"
# Inject the discovered LocalStack IP into the Endpoints placeholder at apply
# time, so the in-cluster DNS name routes to wherever podman put the container.
sed "s/__LOCALSTACK_IP__/$LS_IP/" "$ROOT/crossplane/localstack-service.yaml" \
  | kubectl apply --server-side -f - >/dev/null

echo "==> 5/10  Crossplane function"
kubectl apply -f "$ROOT/crossplane/function-patch-and-transform.yaml" >/dev/null

echo "==> 6/10  providers (v2): runtime config -> provider-aws-s3 + provider-terraform"
# DeploymentRuntimeConfig must exist before the provider reconciles so the
# revision is created with the stable ServiceAccount (provider-aws-s3).
kubectl apply -f "$ROOT/crossplane/provider-aws-s3-runtime.yaml" >/dev/null
kubectl apply -f "$ROOT/crossplane/providers.yaml" >/dev/null

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
  providers.pkg.crossplane.io/provider-terraform \
  --timeout=420s >/dev/null

echo "==> 7/10  ProviderConfigs + XRD + Composition"
kubectl apply -f "$ROOT/crossplane/aws-creds-secret.yaml" >/dev/null
kubectl apply -f "$ROOT/crossplane/provider-config.yaml" >/dev/null
kubectl apply -f "$ROOT/crossplane/provider-config-terraform.yaml" >/dev/null
kubectl apply -f "$ROOT/crossplane/xrd.yaml" >/dev/null
kubectl apply -f "$ROOT/crossplane/composition.yaml" >/dev/null

echo "==> 8/10  demo app (Helm: XBucket XR + ConfigMap + Deployment)"
helm upgrade --install demo-app "$ROOT/charts/demo-app" -n demo-app --create-namespace >/dev/null

echo "      waiting for XBucket demo-app to become Ready..."
kubectl -n demo-app wait xbucket/demo-app --for=condition=Ready --timeout=300s >/dev/null

echo "==> 9/10  Vault sync: composed terraform Workspace writes crossplane/demo-app-bucket"
echo "       waiting for the composed Workspace to land the value in Vault..."
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
echo "All up. Proof commands:"
echo "  kubectl -n demo-app logs deploy/demo-app                                              # producer writing the dynamic bucket"
echo "  kubectl -n demo-app-2 logs deploy/demo-app-2                                          # consumer reading it back from Vault"
echo "  kubectl -n demo-app-2 get externalsecret,secret                                       # ExternalSecret -> local Secret"
echo "  kubectl -n rss exec vault-0 -- vault kv get secret/crossplane/demo-app-bucket         # the shared value in Vault"
echo "  podman exec localstack awslocal s3api list-buckets                                    # the shared bucket"
echo "  ./scripts/down.sh                                                                     # teardown"
