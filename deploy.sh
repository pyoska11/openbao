#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="openbao"
KUBE_CONTEXT="kind-openbao"
NAMESPACE="openbao"
NODE_IMAGE="kindest/node:v1.34.8"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

for command in docker helm jq kind kubectl; do require "$command"; done
docker info >/dev/null

if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  kind create cluster --name "$CLUSTER_NAME" --image "$NODE_IMAGE" \
    --config "$ROOT_DIR/kind-config.yaml" --wait 5m
fi

echo "==> Loading workload images into Kind"
for image in \
  ghcr.io/cloudnative-pg/cloudnative-pg:1.30.0 \
  quay.io/openbao/openbao:2.4.0 \
  ghcr.io/cloudnative-pg/postgresql:18.6-202608310817-minimal-trixie@sha256:5c389b0268d9e637ca55efa41a7fafa3996332b5ea3c6099d0861c5f31acb00e \
  ghcr.io/cloudnative-pg/postgresql:18-minimal-trixie; do
  kind load docker-image "$image" --name "$CLUSTER_NAME"
done

kubectl config use-context "$KUBE_CONTEXT" >/dev/null

echo "==> Applying playground-compatible node labels and topology"
kubectl label node -l postgres.node.kubernetes.io node-role.kubernetes.io/postgres= --overwrite
kubectl label node -l infra.node.kubernetes.io node-role.kubernetes.io/infra= --overwrite
kubectl label node -l app.node.kubernetes.io node-role.kubernetes.io/app= --overwrite
kubectl label nodes --all --overwrite topology.kubernetes.io/region=openbao topology.kubernetes.io/zone=openbao-1
zone=1
while IFS= read -r node; do
  kubectl label "$node" --overwrite "topology.kubernetes.io/zone=openbao-$zone"
  zone=$((zone + 1))
done < <(kubectl get nodes -l postgres.node.kubernetes.io -o name | sort)

echo "==> Installing CloudNativePG"
helm upgrade --install cnpg "$ROOT_DIR/chart/cloudnative-pg" \
  --namespace cnpg-system --create-namespace --version 0.29.0 \
  --set config.clusterWide=true --wait --timeout 10m

echo "==> Installing the playground-compatible PostgreSQL image catalog"
kubectl apply -f "$ROOT_DIR/manifests/catalog-minimal-trixie.yaml"

echo "==> Creating CNPG PostgreSQL cluster and certificate-authenticated roles"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "$NAMESPACE" -f "$ROOT_DIR/manifests/cnpg-stack.yaml"
kubectl wait --for=condition=Ready cluster/openbao-db -n "$NAMESPACE" --timeout=15m

echo "==> Initialising the OpenBao schema"
kubectl delete job openbao-schema-init -n "$NAMESPACE" --ignore-not-found >/dev/null
kubectl apply -n "$NAMESPACE" -f "$ROOT_DIR/manifests/schema-init-job.yaml"
kubectl wait --for=condition=complete job/openbao-schema-init -n "$NAMESPACE" --timeout=5m

echo "==> Installing OpenBao"
helm upgrade --install openbao "$ROOT_DIR/chart/openbao" \
  --namespace "$NAMESPACE" --version 0.18.0 \
  -f "$ROOT_DIR/manifests/openbao-values.yaml" \
  --wait --timeout 10m

echo "==> Initialising and unsealing OpenBao"
"$ROOT_DIR/bootstrap.sh"

echo "==> Running OpenBao/PostgreSQL smoke test"
"$ROOT_DIR/verify.sh"

echo
echo "Deployment is ready. Context: $KUBE_CONTEXT"
kubectl get pods -n "$NAMESPACE" -o wide
echo
echo "Credentials are stored locally with mode 0600 in: $ROOT_DIR/.openbao/"
echo "Port-forward the UI/API with:"
echo "  kubectl --context $KUBE_CONTEXT -n $NAMESPACE port-forward svc/openbao 8200:8200"
