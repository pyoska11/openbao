#!/usr/bin/env bash
set -Eeuo pipefail

: "${1:?usage: $0 path field}"
: "${2:?usage: $0 path field}"

path="$1"
field="$2"

jwt="$(kubectl --context kind-openbao create token secret-copy \
  -n openbao --audience=vault --duration=10m)"

token="$(kubectl --context kind-openbao exec -n openbao openbao-0 -- \
  env BAO_ADDR=http://127.0.0.1:8200 \
  bao write -field=token auth/kubernetes/login \
  role=secret-source-writer jwt="$jwt")"
  
# Generate a random 32-byte value for the demo secret.
value="$(openssl rand -hex 32)"

# Store the secret in the source OpenBao KV engine.
kubectl --context kind-openbao exec -n openbao openbao-0 -- \
  env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$token" \
  bao kv put "secret/$path" "$field=$value"
fingerprint="$(printf '%s' "$value" | openssl dgst -sha256 -r | awk '{print $1}')"
printf 'stored secret/%s (field=%s, sha256=%s)\n' "$path" "$field" "$fingerprint"
