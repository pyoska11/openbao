# Production-style secret operations

This extends the CNPG Recipe 27 deployment with two least-privilege workflows:

1. Generate a random key and store it in KV v2.
2. Copy one selected field from a source Vault/OpenBao to a destination Vault/OpenBao.

Both workflows use one authentication mechanism only: Kubernetes Auth. AppRole and SecretID are not used. The local demo uses two independently initialized OpenBao instances backed by separate CNPG databases. PostgreSQL data is never copied between them.

## Prepare the local demo

```bash
./deploy.sh
./ops/setup-secret-demo.sh
```

The same steps can be run as `make deploy` and `make demo`.

The second script reuses the same CNPG/OpenBao manifests in namespace `openbao-destination`. It configures Kubernetes Auth on both instances and installs exact-path policies. The tutorial's CNPG schema, PostgreSQL storage backend, HA configuration, TLS certificate mounts, and unseal flow remain unchanged.

The local service addresses are:

```text
source:      http://openbao.openbao.svc.cluster.local:8200
destination: http://openbao-destination.openbao-destination.svc.cluster.local:8200
```

## Kubernetes Auth roles

The setup script creates one Kubernetes Auth method on each OpenBao instance:

```text
secret-source-read       -> read the source path
secret-source-writer     -> create/update the source path
secret-copy-source       -> read the source path for the copy Job
secret-copy-destination  -> create/update/read the destination path
```

The copy role is bound to ServiceAccount `secret-copy` in namespace `openbao`, with JWT audience `vault`. The Job receives a projected, 10-minute ServiceAccount JWT and exchanges it for OpenBao tokens with a five-minute TTL. No credential is persisted in a Kubernetes Secret.

## 1. Create and store a key

The script runs `bao` inside the source OpenBao pod, so no Vault CLI or port-forward is required:

```bash
./ops/create-secret-key.sh shared/generated-key secret_key
```

The script generates 32 random bytes encoded as hex unless `SECRET_VALUE` is explicitly supplied. It prints only a SHA-256 fingerprint, never the plaintext value.

For production, use HTTPS with a trusted CA and obtain the ServiceAccount JWT through the workload's Kubernetes identity. Do not use `VAULT_SKIP_VERIFY` or `curl -k`.

## 2. Copy with a Kubernetes Job

```bash
./ops/run-copy-job.sh shared/generated-key shared/generated-key secret_key
```

The Job authenticates separately to source and destination using the same projected JWT. Its source and destination policies are different, so the source token cannot write and the destination token cannot read the source. The wrapper creates a temporary ConfigMap containing only addresses and paths, waits for completion, prints the verification result, and removes the ConfigMap on exit.

For a real destination, configure its Kubernetes Auth method to trust the Kubernetes cluster that runs the Job, or run the Job in the destination cluster with the appropriate bound ServiceAccount. Do not synchronize OpenBao PostgreSQL tables between independent clusters.

## Verification for the report

The expected Job output is:

```text
secret copy and verification passed
```

Check completion and cleanup:

```bash
kubectl --context kind-openbao -n openbao get job secret-copy
kubectl --context kind-openbao -n openbao get configmap secret-copy-config
```

The Job must show `1/1` completion. The ConfigMap check must return `NotFound`; it contains no credentials and is removed automatically.

The report evidence is: Job `Complete`, ConfigMap absent, matching source/destination SHA-256 fingerprints, and no plaintext key in terminal output or logs. The Job itself performs the equality check without logging the value.

## Security requirements

- Use HTTPS and trusted CA certificates outside this local lab.
- Keep policies exact-path and token TTLs short.
- Enable audit logging and monitor Kubernetes Auth login/write events.
- Rotate the secret after a migration when the source value is no longer needed.
- For high-value cryptographic material, prefer Vault/OpenBao Transit and transfer wrapped ciphertext instead of plaintext key material.
