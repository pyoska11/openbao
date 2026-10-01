#!/usr/bin/env bash
set -Eeuo pipefail

context=kind-openbao
destination_namespace=openbao-destination
root=.openbao

command -v kubectl >/dev/null || { echo 'missing required command: kubectl' >&2; exit 1; }
command -v helm >/dev/null || { echo 'missing required command: helm' >&2; exit 1; }
command -v jq >/dev/null || { echo 'missing required command: jq' >&2; exit 1; }
[ -s "$root/root-token" ] || { echo 'run ./deploy.sh first' >&2; exit 1; }

kubectl() {
  command kubectl --context "$context" "$@"
}

wait_for_pod() {
  kubectl wait --for=jsonpath='{.status.phase}'=Running \
    -n "$1" "pod/$2" --timeout=5m >/dev/null
}

bao_status() {
  local namespace=$1 pod=$2 output code

  if output="$(kubectl exec -n "$namespace" "$pod" -- bao status 2>&1)"; then
    printf '%s\n' "$output"
    return 0
  else
    code=$?
  fi

  [ "$code" -eq 2 ] || {
    printf '%s\n' "$output" >&2
    return "$code"
  }
  printf '%s\n' "$output"
  return 0
}

unseal_cluster() {
  local namespace=$1 leader=$2 init_file=$3
  shift 3

  wait_for_pod "$namespace" "$leader"
  local status
  if ! status="$(bao_status "$namespace" "$leader")"; then
    echo "$status" >&2
    exit 1
  fi

  if ! grep -q 'Initialized.*true' <<<"$status"; then
    [ ! -e "$init_file" ] || {
      echo "refusing to overwrite $init_file" >&2
      exit 1
    }
    umask 077
    kubectl exec -n "$namespace" "$leader" -- bao operator init -format=json > "$init_file"
    chmod 600 "$init_file"
  fi

  [ -s "$init_file" ] || { echo "missing $init_file" >&2; exit 1; }
  local key1 key2 key3 pod
  key1="$(jq -r '.unseal_keys_b64[0]' "$init_file")"
  key2="$(jq -r '.unseal_keys_b64[1]' "$init_file")"
  key3="$(jq -r '.unseal_keys_b64[2]' "$init_file")"

  for pod in "$leader" "$@"; do
    wait_for_pod "$namespace" "$pod"
    if grep -q 'Sealed.*true' <<<"$(bao_status "$namespace" "$pod")"; then
      kubectl exec -n "$namespace" "$pod" -- bao operator unseal "$key1" >/dev/null
      kubectl exec -n "$namespace" "$pod" -- bao operator unseal "$key2" >/dev/null
      kubectl exec -n "$namespace" "$pod" -- bao operator unseal "$key3" >/dev/null
    fi
    kubectl wait --for=condition=Ready -n "$namespace" "pod/$pod" --timeout=5m >/dev/null
  done
}

destination_init="$root/destination-init.json"
destination_token_file="$root/destination-root-token"

kubectl create namespace "$destination_namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "$destination_namespace" -f manifests/cnpg-stack.yaml
kubectl wait --for=condition=Ready cluster/openbao-db -n "$destination_namespace" --timeout=15m
kubectl delete job openbao-schema-init -n "$destination_namespace" --ignore-not-found >/dev/null
kubectl apply -n "$destination_namespace" -f manifests/schema-init-job.yaml
kubectl wait --for=condition=complete job/openbao-schema-init -n "$destination_namespace" --timeout=5m

helm upgrade --install openbao-destination chart/openbao \
  --namespace "$destination_namespace" \
  -f manifests/openbao-values.yaml --wait --timeout 10m

unseal_cluster "$destination_namespace" openbao-destination-0 "$destination_init" \
  openbao-destination-1 openbao-destination-2
jq -r '.root_token' "$destination_init" > "$destination_token_file"
chmod 600 "$destination_token_file"

echo 'Secret demo source and destination are ready.'
echo 'Source:      namespace openbao, service openbao'
echo 'Destination: namespace openbao-destination, service openbao-destination'
