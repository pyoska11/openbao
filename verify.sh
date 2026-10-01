#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="openbao"
ROOT_TOKEN_FILE="${OPENBAO_CREDENTIALS_DIR:-$ROOT_DIR/.openbao}/root-token"

[ -s "$ROOT_TOKEN_FILE" ] || { echo "missing root token: $ROOT_TOKEN_FILE" >&2; exit 1; }
ROOT_TOKEN="$(cat "$ROOT_TOKEN_FILE")"

if ! kubectl exec -n "$NAMESPACE" openbao-0 -- env BAO_TOKEN="$ROOT_TOKEN" bao secrets list -format=json 2>/dev/null | jq -e 'has("secret/")' >/dev/null; then
  kubectl exec -n "$NAMESPACE" openbao-0 -- env BAO_TOKEN="$ROOT_TOKEN" bao secrets enable -path=secret kv-v2 >/dev/null
fi

kubectl exec -n "$NAMESPACE" openbao-0 -- env BAO_TOKEN="$ROOT_TOKEN" \
  bao kv put secret/test-app username=admin password=supersecretpassword >/dev/null

result="$(kubectl exec -n "$NAMESPACE" openbao-0 -- env BAO_TOKEN="$ROOT_TOKEN" \
  bao kv get -format=json secret/test-app | jq -r '.data.data.username + ":" + .data.data.password')"
[ "$result" = "admin:supersecretpassword" ] || { echo "OpenBao KV smoke test failed" >&2; exit 1; }

rows="$(kubectl exec -n "$NAMESPACE" openbao-db-1 -- psql -U postgres -d openbao -tAc \
  'SELECT count(*) FROM openbao_kv_store;')"
[ "${rows//[[:space:]]/}" -gt 0 ] || { echo "PostgreSQL storage table is empty" >&2; exit 1; }

echo "KV read/write OK; PostgreSQL contains ${rows//[[:space:]]/} encrypted storage rows"
