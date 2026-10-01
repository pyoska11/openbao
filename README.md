# OpenBao + CloudNativePG on Kind / OrbStack

Hướng dẫn tiếng Việt theo trình tự tutorial nằm tại [HUONG-DAN.md](HUONG-DAN.md).

This is a local implementation of [CNPG Recipe 27](https://www.gabrielebartolini.it/articles/2026/08/cnpg-recipe-27-running-openbao-on-kubernetes-with-a-cloudnativepg-postgresql-backend/), using a direct six-node Kind cluster on OrbStack. The node roles, taints, labels, zones, and PostgreSQL image catalog match `cnpg-playground`; the playground runtime itself is not installed.

The additional production-style secret workflows are documented in [OPERATIONS.md](OPERATIONS.md): generate a KV v2 key and copy it between Vault/OpenBao instances with Kubernetes Auth and least-privilege policies.

## Prerequisites

- OrbStack running with Docker
- `docker`, `kubectl`, `helm`, `kind`, and `jq`

The CloudNativePG and OpenBao charts are vendored under `chart/`, and the required PostgreSQL image catalog is vendored under `manifests/`; deployment uses these local files.

## Run

```sh
make deploy
```

Common local commands are also available through `make`:

```sh
make deploy
make demo
make verify
make lint
make stop
make start
```

`make stop` pauses the Kind node containers without deleting the cluster. Use `make start` to resume it, or `make destroy` only when the cluster should be removed.

The script creates `kind-openbao` with `kindest/node:v1.34.8` passed to `kind create cluster`, one control-plane node, one infrastructure node, one application node, and three tainted PostgreSQL nodes. It applies the playground-compatible topology and `ClusterImageCatalog`, deploys the 3-instance PostgreSQL cluster, runs the schema-init Job, installs OpenBao with three replicas backed by PostgreSQL, initialises/unseals it, and runs a KV smoke test.

The generated unseal keys and root token are written under `.openbao/` with restrictive permissions and excluded from Git.

To reproduce the two-Vault secret demo after the main deployment:

```sh
make demo
```

This separate demo script reuses the same CNPG/OpenBao manifests in a second namespace, then configures Kubernetes Auth and policies on both instances. It is not part of the production source deployment. The local demo uses the same Kubernetes Job copy path with in-cluster Service DNS.

For the Kubernetes-native production path, run the copy as a one-shot Job:

```sh
./ops/run-copy-job.sh
```

To access the UI/API locally:

```sh
kubectl --context kind-openbao -n openbao port-forward svc/openbao 8200:8200
```

Then open <http://127.0.0.1:8200>.

## Remove

```sh
kind delete cluster --name openbao
```

This removes the local cluster and its local-path volumes.
