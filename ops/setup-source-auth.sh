#!/usr/bin/env bash
set -Eeuo pipefail

namespace=openbao
pod=openbao-0
token="$(cat .openbao/root-token)"

# Create the ServiceAccount and TokenReview permissions used by Kubernetes Auth.
kubectl --context kind-openbao apply -f manifests/secret-copy-auth.yaml

# Enable the KV engine used to store the source secret.
kubectl --context kind-openbao -n "$namespace" exec "$pod" -- \
  env BAO_TOKEN="$token" bao secrets enable -path=secret kv-v2

# Enable Kubernetes Auth for short-lived ServiceAccount logins.
kubectl --context kind-openbao -n "$namespace" exec "$pod" -- \
  env BAO_TOKEN="$token" bao auth enable kubernetes

ca="$(kubectl --context kind-openbao get configmap kube-root-ca.crt \
  -n "$namespace" -o jsonpath='{.data.ca\.crt}')"
kubectl --context kind-openbao -n "$namespace" exec "$pod" -- \
  env BAO_TOKEN="$token" bao write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443 \
  kubernetes_ca_cert="$ca"

# Configure the policy used to write the source secret.
kubectl --context kind-openbao -n "$namespace" exec -i "$pod" -- \
  env BAO_TOKEN="$token" bao policy write secret-source-write - \
  < ops/source-write.hcl

# Allow the source ServiceAccount to create or update the source secret.
kubectl --context kind-openbao -n "$namespace" exec "$pod" -- \
  env BAO_TOKEN="$token" bao write auth/kubernetes/role/secret-source-writer \
  token_policies=secret-source-write token_ttl=5m token_max_ttl=15m \
  bound_service_account_names=secret-copy \
  bound_service_account_namespaces=openbao audience=vault

echo 'Source Kubernetes Auth is ready.'
