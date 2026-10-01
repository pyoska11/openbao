# Chạy OpenBao trên Kubernetes với CloudNativePG làm PostgreSQL backend

Tài liệu này bám theo [CNPG Recipe 27](https://www.gabrielebartolini.it/articles/2026/08/cnpg-recipe-27-running-openbao-on-kubernetes-with-a-cloudnativepg-postgresql-backend/), nhưng dùng một Kind cluster tự tạo thay cho việc cài `cnpg-playground` đầy đủ. Các ý chính của recipe vẫn được giữ nguyên:

- CloudNativePG quản lý PostgreSQL HA gồm ba instances.
- PostgreSQL xác thực bằng client certificate do `DatabaseRole` cấp.
- OpenBao dùng storage backend `postgresql` thay vì local Raft/PVC.
- OpenBao chạy HA với ba replicas.
- Bảng storage và quyền runtime được tạo trước bằng một Job chạy bằng schema owner.

Hai workflow bổ sung ở cuối tài liệu dùng Kubernetes Auth:

1. Tạo một secret key trong OpenBao source.
2. Copy secret key từ source sang một OpenBao destination độc lập bằng Kubernetes Job.

## Kiến trúc

```text
Kind cluster: kind-openbao
│
├── CloudNativePG operator
│
├── Namespace openbao
│   ├── openbao-db-1/2/3          PostgreSQL HA
│   ├── openbao-schema-init       Job tạo schema và grant quyền
│   └── openbao-0/1/2             OpenBao HA
│       └── storage: PostgreSQL qua mTLS
│
└── Namespace openbao-destination
    ├── openbao-db-1/2/3          PostgreSQL HA độc lập
    └── openbao-destination-0/1/2 OpenBao destination độc lập
```

OpenBao kết nối tới Service `openbao-db-rw`. Service này trỏ tới PostgreSQL primary. CNPG tự quản lý replication tới hai standby. OpenBao dùng hai bảng riêng:

- `openbao_kv_store`: dữ liệu storage đã mã hoá của OpenBao.
- `openbao_ha_locks`: lock dùng cho HA.

PostgreSQL không lưu plaintext secret của KV. OpenBao mã hoá payload trước khi ghi vào `value BYTEA`.

## Trình tự thực hiện từ đầu đến cuối

Phần triển khai nên được trình bày theo đúng thứ tự dependency của hệ thống. Với mỗi bước, báo cáo nên nêu file cấu hình, lệnh chạy và kết quả mong đợi.

### Bước 1 — Tạo Kind cluster

File: `kind-config.yaml`.

```bash
docker pull kindest/node:v1.34.8
kind create cluster --name openbao \
  --image kindest/node:v1.34.8 \
  --config kind-config.yaml --wait 5m
```

Kết quả: cluster có 6 node, gồm control-plane, infra, app và 3 PostgreSQL nodes.

### Bước 2 — Cài CloudNativePG operator

Chart: `chart/cloudnative-pg/`.

```bash
helm upgrade --install cnpg chart/cloudnative-pg \
  --namespace cnpg-system --create-namespace \
  --version 0.29.0 --set config.clusterWide=true \
  --wait --timeout 10m
```

Kết quả: operator CloudNativePG sẵn sàng quản lý PostgreSQL resources.

### Bước 3 — Cài PostgreSQL image catalog

File: `manifests/catalog-minimal-trixie.yaml`.

```bash
kubectl apply -f manifests/catalog-minimal-trixie.yaml
```

Kết quả: catalog `postgresql-minimal-trixie` cung cấp PostgreSQL 18 image đã pin digest.

### Bước 4 — Tạo CNPG cluster, roles và database

File: `manifests/cnpg-stack.yaml`.

```bash
kubectl create namespace openbao \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n openbao -f manifests/cnpg-stack.yaml
kubectl wait --for=condition=Ready cluster/openbao-db \
  -n openbao --timeout=15m
```

Kết quả: CNPG tạo `openbao-db`, hai `DatabaseRole` và database `openbao`.

### Bước 5 — Chờ certificate Secret từ CNPG

```bash
kubectl -n openbao get secrets
kubectl -n openbao get pods
```

Phải có các Secret `role-openbao-client-cert`, `role-openbao-rw-client-cert` và `openbao-db-ca`.

### Bước 6 — Tạo schema và cấp quyền runtime

File: `manifests/schema-init-job.yaml`.

```bash
kubectl apply -n openbao -f manifests/schema-init-job.yaml
kubectl wait --for=condition=complete job/openbao-schema-init \
  -n openbao --timeout=5m
```

Kết quả: Job tạo `openbao_kv_store`, `openbao_ha_locks` và cấp quyền DML tối thiểu cho `openbao-rw`.

### Bước 7 — Cài OpenBao bằng Helm

Chart: `chart/openbao/`; values: `manifests/openbao-values.yaml`.

```bash
helm upgrade --install openbao chart/openbao \
  --namespace openbao --version 0.18.0 \
  -f manifests/openbao-values.yaml \
  --wait --timeout 10m
```

Kết quả: StatefulSet OpenBao được tạo với 3 replicas và PostgreSQL storage backend.

### Bước 8 — Init và unseal

```bash
./bootstrap.sh
```

Kết quả: keys/root token được lưu local, từng OpenBao pod được unseal và chờ `Ready`.

### Bước 9 — Verify phần tutorial

```bash
./verify.sh
```

Kết quả: OpenBao KV read/write thành công và PostgreSQL có encrypted storage rows.

### Bước 10 — Cấu hình Kubernetes Auth cho source

```bash
make source-auth
```

Kết quả: source OpenBao có Kubernetes Auth, policy và role để tạo secret bằng ServiceAccount ngắn hạn.

### Bước 11 — Thực hiện Task 1

```bash
make create-secret
```

Kết quả: secret key được lưu ở `secret/shared/generated-key` trên source.

### Bước 12 — Tạo destination OpenBao

```bash
make demo
```

Kết quả: namespace, CNPG cluster và OpenBao destination được tạo.

Sau đó `make demo` chạy `ops/setup-copy-auth.sh` để tạo Kubernetes Auth roles phục vụ việc copy.

### Bước 13 — Thực hiện Task 2

```bash
kubectl --context kind-openbao apply \
  -f manifests/secret-copy-job.yaml
```

Kết quả: Job đọc source, ghi destination và in `secret copy and verification passed`.

### Bước 14 — Verify hai task

```bash
kubectl -n openbao get job secret-copy \
  -o jsonpath='{.status.succeeded}{"\n"}'
```

Kết quả phải là `1`. Sau đó in source và destination secret theo phần verify tương ứng bên dưới.

Trong báo cáo, không nên bắt đầu từ secret workflow. Secret workflow chỉ có thể chạy sau khi PostgreSQL schema, quyền runtime, OpenBao storage backend và Kubernetes Auth đã hoàn tất.

Flow tương ứng:

```text
Kind
  → CloudNativePG operator
  → ClusterImageCatalog
  → CNPG PostgreSQL Cluster/DatabaseRole/Database
  → schema-init Job
  → OpenBao Helm release
  → init/unseal
  → PostgreSQL/KV verification
  → destination OpenBao
  → Task 1: create secret
  → Task 2: copy secret
  → final verification
```

Các target Makefile gom nhiều bước thành một lệnh, nhưng phần giải thích trong báo cáo vẫn nên tách theo flow trên:

```bash
make deploy
make demo
./ops/create-secret-key.sh shared/generated-key secret_key
./ops/run-copy-job.sh
```

## 1. Chuẩn bị môi trường

Yêu cầu:

- Docker hoặc OrbStack
- Kind
- kubectl
- Helm
- jq
- openssl

Các chart đã nằm local trong thư mục `chart/`:

```text
chart/cloudnative-pg/
chart/openbao/
```

### Tải chart về dạng thư mục local

Chart CloudNativePG được lấy từ Helm repository chính thức:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm pull cnpg/cloudnative-pg \
  --version 0.29.0 \
  --untar \
  --untardir chart
```

Chart OpenBao được lấy từ Helm repository chính thức:

```bash
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update
helm pull openbao/openbao \
  --version 0.18.0 \
  --untar \
  --untardir chart
```

Sau khi tải, Helm sử dụng trực tiếp các thư mục local:

```bash
helm upgrade --install cnpg chart/cloudnative-pg ...
helm upgrade --install openbao chart/openbao ...
```

Nhờ vậy quá trình triển khai không cần tải chart từ internet lần nữa.

Các image chính:

```text
Kind node:       kindest/node:v1.34.8
CNPG operator:   ghcr.io/cloudnative-pg/cloudnative-pg:1.30.0
OpenBao:         quay.io/openbao/openbao:2.4.0
PostgreSQL:      ghcr.io/cloudnative-pg/postgresql:18.6-202608310817-minimal-trixie
```

`make deploy` sẽ pull các image này trước và load chúng vào Kind.

## 2. Tạo Kind cluster

Topology của cluster được khai báo trong `kind-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: openbao
nodes:
- role: control-plane
- role: worker
  labels:
    infra.node.kubernetes.io:
- role: worker
  labels:
    app.node.kubernetes.io:
- role: worker
  labels:
    postgres.node.kubernetes.io:
```

Ba node PostgreSQL có taint để workload thông thường không bị schedule lên đó. Image node được truyền đúng qua lệnh Kind trong `deploy.sh`:

```bash
kind create cluster \
  --name openbao \
  --image kindest/node:v1.34.8 \
  --config kind-config.yaml \
  --wait 5m
```

Chạy toàn bộ bước chuẩn bị và tạo cluster bằng:

```bash
make deploy
```

## 3. Cài CloudNativePG và ClusterImageCatalog

`deploy.sh` cài chart CloudNativePG local:

```bash
helm upgrade --install cnpg chart/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace \
  --version 0.29.0 \
  --set config.clusterWide=true \
  --wait --timeout 10m
```

Sau đó cài `ClusterImageCatalog`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ClusterImageCatalog
metadata:
  name: postgresql-minimal-trixie
spec:
  images:
    - major: 18
      image: ghcr.io/cloudnative-pg/postgresql:18.6-202608310817-minimal-trixie@sha256:5c389b0268d9e637ca55efa41a7fafa3996332b5ea3c6099d0861c5f31acb00e
```

Cluster PostgreSQL tham chiếu catalog thay vì ghi image trực tiếp:

```yaml
spec:
  instances: 3
  imageCatalogRef:
    apiGroup: postgresql.cnpg.io
    kind: ClusterImageCatalog
    name: postgresql-minimal-trixie
    major: 18
```

Cách này cho phép CNPG quản lý image PostgreSQL theo catalog và giữ manifest Cluster ổn định.

## 4. Tạo CNPG PostgreSQL cluster

Phần chính trong `manifests/cnpg-stack.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: openbao-db
spec:
  instances: 3
  imageCatalogRef:
    apiGroup: postgresql.cnpg.io
    kind: ClusterImageCatalog
    name: postgresql-minimal-trixie
    major: 18
  affinity:
    nodeSelector:
      node-role.kubernetes.io/postgres: ""
    tolerations:
      - key: node-role.kubernetes.io/postgres
        operator: Exists
        effect: NoSchedule
    enablePodAntiAffinity: true
    topologyKey: topology.kubernetes.io/zone
    podAntiAffinityType: required
  storage:
    size: 2Gi
```

### Vì sao có `affinity` và `tolerations`?

- `nodeSelector` ép PostgreSQL chạy trên ba node có label PostgreSQL.
- `tolerations` cho phép PostgreSQL chạy trên node có taint PostgreSQL.
- `podAntiAffinity` yêu cầu ba instances nằm trên các node/zone khác nhau.

Trong môi trường production, các node PostgreSQL nên là node riêng có storage phù hợp. Cấu hình Kind trong project chỉ là profile local theo topology của playground.

### Replication đồng bộ

```yaml
postgresql:
  synchronous:
    method: any
    number: 1
```

CNPG yêu cầu ít nhất một standby đồng bộ xác nhận transaction. Điều này ưu tiên RPO bằng 0, nhưng nếu không còn standby đủ điều kiện thì write có thể bị dừng.

### PostgreSQL chỉ nhận mTLS certificate

```yaml
postgresql:
  pg_hba:
    - hostssl openbao openbao all cert
    - hostssl openbao openbao-rw all cert
    - hostnossl openbao openbao all reject
    - hostnossl openbao openbao-rw all reject
```

Hai role không dùng password. Kết nối TLS không có certificate bị reject.

## 5. Tạo DatabaseRole và Database

Role `openbao` là schema owner, dùng cho DDL một lần. Role `openbao-rw` là runtime role của OpenBao, chỉ có quyền DML cần thiết.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: role-openbao
spec:
  cluster:
    name: openbao-db
  name: openbao
  login: true
  clientCertificate:
    enabled: true
  databaseRoleReclaimPolicy: retain
---
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: role-openbao-rw
spec:
  cluster:
    name: openbao-db
  name: openbao-rw
  login: true
  clientCertificate:
    enabled: true
  databaseRoleReclaimPolicy: retain
```

Database được tạo với owner là role `openbao`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: openbao-db
spec:
  name: openbao
  owner: openbao
  cluster:
    name: openbao-db
```

Sau khi CNPG reconcile xong, các Secret certificate được tạo:

```text
role-openbao-client-cert
role-openbao-rw-client-cert
```

Private key được mount với `defaultMode: 0640` để libpq chấp nhận quyền file khi chạy với `fsGroup`.

Kiểm tra CNPG:

```bash
kubectl --context kind-openbao \
  -n openbao \
  get cluster openbao-db

kubectl --context kind-openbao \
  -n openbao \
  get pods
```

## 6. Tạo schema OpenBao bằng Job

Đây là phần quan trọng nhất của recipe.

`DatabaseRole` tạo role và certificate, nhưng không tự quản lý table-level grants. Vì vậy project chạy một Job bằng schema owner `openbao` để:

1. Tạo bảng `openbao_kv_store`.
2. Tạo index theo `parent_path`.
3. Tạo bảng `openbao_ha_locks`.
4. Grant `SELECT, INSERT, UPDATE, DELETE` cho `openbao-rw`.
5. Chặn `PUBLIC` khỏi database và schema.
6. Chỉ grant lại quyền cần thiết cho `openbao-rw`.

### SQL được chạy

Trong `manifests/schema-init-job.yaml`, container chạy `psql` bằng certificate:

```yaml
command:
  - psql
  - postgres://openbao@openbao-db-rw:5432/openbao?sslmode=verify-full&sslcert=/etc/certs/tls.crt&sslkey=/etc/certs/tls.key&sslrootcert=/etc/ca/ca.crt
  - -v
  - ON_ERROR_STOP=1
  - -c
  - |
    CREATE TABLE IF NOT EXISTS openbao_kv_store (
      parent_path TEXT NOT NULL,
      path TEXT NOT NULL,
      key TEXT NOT NULL,
      value BYTEA,
      CONSTRAINT openbao_kv_store_pkey PRIMARY KEY (path, key)
    );

    CREATE INDEX IF NOT EXISTS openbao_kv_store_idx
      ON openbao_kv_store (parent_path);

    CREATE TABLE IF NOT EXISTS openbao_ha_locks (
      ha_key TEXT NOT NULL,
      ha_identity TEXT NOT NULL,
      ha_value TEXT,
      valid_until TIMESTAMP WITH TIME ZONE NOT NULL,
      CONSTRAINT openbao_ha_locks_pkey PRIMARY KEY (ha_key)
    );

    GRANT SELECT, INSERT, UPDATE, DELETE
      ON TABLE openbao_kv_store, openbao_ha_locks
      TO "openbao-rw";

    REVOKE CONNECT ON DATABASE openbao FROM PUBLIC;
    GRANT CONNECT ON DATABASE openbao TO "openbao-rw";
    REVOKE ALL ON SCHEMA public FROM PUBLIC;
    GRANT USAGE ON SCHEMA public TO "openbao-rw";
```

### Vì sao phải tạo bảng trước?

OpenBao có thể tự tạo table storage, nhưng role `openbao-rw` được thiết kế không có quyền `CREATE`. Vì vậy bảng phải được tạo trước bằng owner role, sau đó OpenBao chạy với:

```hcl
skip_create_table = "true"
```

Nếu bỏ bước này, OpenBao runtime sẽ không thể tự tạo bảng khi khởi động.

Job mount certificate như sau:

```yaml
volumes:
  - name: certs
    secret:
      secretName: role-openbao-client-cert
      defaultMode: 0640
  - name: ca
    secret:
      secretName: openbao-db-ca
      defaultMode: 0640
```

Deploy và chờ Job:

```bash
kubectl --context kind-openbao \
  -n openbao \
  apply -f manifests/schema-init-job.yaml

kubectl --context kind-openbao \
  -n openbao \
  wait --for=condition=complete \
  job/openbao-schema-init --timeout=5m
```

Trong project, `deploy.sh` tự chạy hai lệnh này.

## 7. Cấu hình và deploy OpenBao

OpenBao không dùng local data PVC trong recipe này:

```yaml
server:
  dataStorage:
    enabled: false
```

OpenBao chạy HA ba replicas:

```yaml
server:
  ha:
    enabled: true
    replicas: 3
```

Storage backend được cấu hình trong `manifests/openbao-values.yaml`:

```hcl
storage "postgresql" {
  connection_url = "postgres://openbao-rw@openbao-db-rw:5432/openbao?sslmode=verify-full&sslcert=/etc/openbao/certs/tls.crt&sslkey=/etc/openbao/certs/tls.key&sslrootcert=/etc/openbao/ca/ca.crt"
  table = "openbao_kv_store"
  ha_table = "openbao_ha_locks"
  ha_enabled = "true"
  skip_create_table = "true"
}
```

Certificate và CA được mount vào OpenBao:

```yaml
server:
  volumes:
    - name: cnpg-client-cert
      secret:
        secretName: role-openbao-rw-client-cert
        defaultMode: 0640
    - name: cnpg-client-ca
      secret:
        secretName: openbao-db-ca
        defaultMode: 0640
  volumeMounts:
    - name: cnpg-client-cert
      mountPath: /etc/openbao/certs
      readOnly: true
    - name: cnpg-client-ca
      mountPath: /etc/openbao/ca
      readOnly: true
```

`tls_disable = 1` chỉ dùng cho HTTP listener trong local lab. PostgreSQL connection vẫn dùng TLS và verify-full.

Deploy chart local:

```bash
helm upgrade --install openbao chart/openbao \
  --namespace openbao \
  --version 0.18.0 \
  -f manifests/openbao-values.yaml \
  --wait --timeout 10m
```

## 8. Init và unseal OpenBao

Sau khi pod chạy, trạng thái ban đầu có thể là:

```text
Initialized: false
Sealed: true
```

Đây là bình thường. Script `bootstrap.sh` thực hiện:

1. Chạy `bao operator init -format=json` trên `openbao-0`.
2. Lưu init JSON trong `.openbao/init.json`.
3. Lưu root token trong `.openbao/root-token`.
4. Đọc ba unseal keys đầu tiên.
5. Unseal từng pod bằng cùng ba keys.
6. Chờ từng pod `Ready`.

Mỗi pod có seal state riêng trong memory. Vì vậy phải unseal lần lượt:

```bash
kubectl --context kind-openbao -n openbao exec openbao-0 -- bao operator unseal <KEY_1>
kubectl --context kind-openbao -n openbao exec openbao-0 -- bao operator unseal <KEY_2>
kubectl --context kind-openbao -n openbao exec openbao-0 -- bao operator unseal <KEY_3>
```

Sau đó lặp lại cho `openbao-1` và `openbao-2`.

Khi unseal xong:

```bash
kubectl --context kind-openbao -n openbao get pods
```

Kết quả cần có:

```text
openbao-0   1/1   Running
openbao-1   1/1   Running
openbao-2   1/1   Running
```

`Storage Type: postgresql` xác nhận OpenBao đang dùng CNPG PostgreSQL backend.

Kiểm tra storage rows:

```bash
./verify.sh
```

## 9. Cấu hình source và Task 1 — Tạo secret key

Trước khi tạo secret, cấu hình Kubernetes Auth cho OpenBao nguồn:

```bash
make source-auth
```

Tạo secret bằng script:

```bash
make create-secret
```

Script không cần `vault` CLI và không cần port-forward. Nó dùng `bao` trong pod `openbao-0`:

```bash
jwt="$(kubectl --context kind-openbao create token secret-copy \
  -n openbao --audience=vault --duration=10m)"

token="$(kubectl --context kind-openbao exec -n openbao openbao-0 -- \
  env BAO_ADDR=http://127.0.0.1:8200 \
  bao write -field=token auth/kubernetes/login \
  role=secret-source-writer jwt="$jwt")"

kubectl --context kind-openbao exec -n openbao openbao-0 -- \
  env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$token" \
  bao kv put secret/shared/generated-key secret_key=<value>
```

Script tự tạo giá trị random 32 bytes dạng hex.

Verify và in key trong local lab:

```bash
SOURCE_TOKEN="$(cat .openbao/root-token)"

kubectl --context kind-openbao -n openbao exec openbao-0 -- \
  env BAO_TOKEN="$SOURCE_TOKEN" \
  bao kv get -field=secret_key secret/shared/generated-key
```

## 10. Task 2 — Copy secret bằng Kubernetes Job

Tạo OpenBao destination độc lập:

```bash
make demo
```

Script này tạo CNPG/OpenBao thứ hai trong namespace `openbao-destination`. Sau đó `ops/setup-copy-auth.sh` cấu hình Kubernetes Auth cho việc đọc ở source và ghi ở destination.

Chạy copy:

```bash
make copy-secret
```

Job dùng một projected JWT với audience `vault`, sau đó login vào hai OpenBao bằng hai role khác nhau:

```text
secret-copy-source       -> read source path
secret-copy-destination  -> create/update/read destination path
```

Job không lưu SecretID. Địa chỉ OpenBao, path và field được khai báo trực tiếp trong manifest.

Kết quả thành công:

```text
secret copy and verification passed
```

## 11. Verify Task 2

Kiểm tra Job:

```bash
kubectl --context kind-openbao \
  -n openbao \
  get job secret-copy \
  -o jsonpath='{.status.succeeded}{"\n"}'
```

Kết quả cần là `1`.

In cả hai secret để so sánh trong local lab:

```bash
SOURCE_TOKEN="$(cat .openbao/root-token)"
DESTINATION_TOKEN="$(cat .openbao/destination-root-token)"

SOURCE_SECRET="$(kubectl --context kind-openbao -n openbao exec openbao-0 -- \
  env BAO_TOKEN="$SOURCE_TOKEN" \
  bao kv get -field=secret_key secret/shared/generated-key)"

DESTINATION_SECRET="$(kubectl --context kind-openbao -n openbao-destination exec openbao-destination-0 -- \
  env BAO_TOKEN="$DESTINATION_TOKEN" \
  bao kv get -field=secret_key secret/shared/generated-key)"

printf 'SOURCE:      %s\n' "$SOURCE_SECRET"
printf 'DESTINATION: %s\n' "$DESTINATION_SECRET"
```

Hai giá trị phải giống nhau.

## 12. Dừng, chạy lại và xoá cluster

Pause cluster nhưng giữ dữ liệu:

```bash
make stop
```

Chạy lại:

```bash
make start
make status
```

Xoá cluster:

```bash
make destroy
```

Tạo lại từ đầu:

```bash
make deploy
make demo
```

## 13. Lưu ý production

- Dùng HTTPS cho listener OpenBao và CA tin cậy.
- Dùng auto-unseal bằng KMS/HSM thay vì lưu Shamir keys trên filesystem.
- Không in plaintext secret trong production.
- Giữ policy exact-path và token TTL ngắn.
- Bật audit logging trên OpenBao.
- Không đồng bộ trực tiếp PostgreSQL storage tables giữa hai OpenBao độc lập.
- Destination production nên có HA/backup riêng và Kubernetes Auth trust boundary rõ ràng.
