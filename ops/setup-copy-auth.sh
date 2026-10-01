#!/usr/bin/env bash
set -Eeuo pipefail

context=kind-openbao
source_namespace=openbao
destination_namespace=openbao-destination
source_pod=openbao-0
destination_pod=openbao-destination-0
source_token="$(cat .openbao/root-token)"
destination_token="$(cat .openbao/destination-root-token)"

kubectl() {
  command kubectl --context "$context" "$@"
}

# Create the ServiceAccount and TokenReview permissions used by the copy Job.
kubectl apply -f manifests/secret-copy-auth.yaml

# Give the source copy role read access to the source secret.
kubectl exec -i -n "$source_namespace" "$source_pod" -- \
  env BAO_TOKEN="$source_token" bao policy write secret-source-read - \
  < ops/source-read.hcl
kubectl exec -n "$source_namespace" "$source_pod" -- \
  env BAO_TOKEN="$source_token" bao write auth/kubernetes/role/secret-copy-source \
  token_policies=secret-source-read token_ttl=5m token_max_ttl=15m \
  bound_service_account_names=secret-copy \
  bound_service_account_namespaces=openbao audience=vault

# Enable KV v2 and Kubernetes Auth on the destination OpenBao.
kubectl exec -n "$destination_namespace" "$destination_pod" -- \
  env BAO_TOKEN="$destination_token" bao secrets enable -path=secret kv-v2
kubectl exec -n "$destination_namespace" "$destination_pod" -- \
  env BAO_TOKEN="$destination_token" bao auth enable kubernetes

ca="$(kubectl get configmap kube-root-ca.crt \
  -n "$destination_namespace" -o jsonpath='{.data.ca\.crt}')"
kubectl exec -n "$destination_namespace" "$destination_pod" -- \
  env BAO_TOKEN="$destination_token" bao write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443 \
  kubernetes_ca_cert="$ca"

# Give the destination copy role permission to read and write the secret.
kubectl exec -i -n "$destination_namespace" "$destination_pod" -- \
  env BAO_TOKEN="$destination_token" bao policy write secret-destination-write-read - \
  < ops/destination-write-read.hcl
kubectl exec -n "$destination_namespace" "$destination_pod" -- \
  env BAO_TOKEN="$destination_token" \
  bao write auth/kubernetes/role/secret-copy-destination \
  token_policies=secret-destination-write-read token_ttl=5m token_max_ttl=15m \
  bound_service_account_names=secret-copy \
  bound_service_account_namespaces=openbao audience=vault

echo 'Copy Kubernetes Auth is ready.'
