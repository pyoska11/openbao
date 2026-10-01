#!/usr/bin/env bash
set -Eeuo pipefail

kubectl --context kind-openbao delete job secret-copy -n openbao --ignore-not-found
kubectl --context kind-openbao apply -f "$(dirname "${BASH_SOURCE[0]}")/../manifests/secret-copy-job.yaml"
kubectl --context kind-openbao wait --for=condition=complete job/secret-copy -n openbao --timeout=5m
kubectl --context kind-openbao logs job/secret-copy -n openbao
