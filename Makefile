SHELL := /bin/bash

CLUSTER := openbao
SOURCE_PATH ?= shared/generated-key
FIELD ?= secret_key

.PHONY: images deploy source-auth demo create-secret copy-secret verify lint start stop status destroy

images:
	docker pull kindest/node:v1.34.8
	docker pull ghcr.io/cloudnative-pg/cloudnative-pg:1.30.0
	docker pull quay.io/openbao/openbao:2.4.0
	docker pull ghcr.io/cloudnative-pg/postgresql:18.6-202608310817-minimal-trixie@sha256:5c389b0268d9e637ca55efa41a7fafa3996332b5ea3c6099d0861c5f31acb00e
	docker pull ghcr.io/cloudnative-pg/postgresql:18-minimal-trixie

deploy: images
	./deploy.sh

source-auth:
	./ops/setup-source-auth.sh

demo:
	./ops/setup-secret-demo.sh
	./ops/setup-copy-auth.sh

create-secret:
	./ops/create-secret-key.sh $(SOURCE_PATH) $(FIELD)

copy-secret:
	./ops/run-copy-job.sh

verify:
	./verify.sh

lint:
	bash -n deploy.sh bootstrap.sh verify.sh ops/*.sh
	shellcheck -x -S warning deploy.sh bootstrap.sh verify.sh ops/*.sh

start:
	docker start $$(docker ps -aq --filter label=io.x-k8s.kind.cluster=$(CLUSTER))

stop:
	docker stop $$(docker ps -q --filter label=io.x-k8s.kind.cluster=$(CLUSTER))

status:
	kind get clusters
	kubectl --context kind-$(CLUSTER) get nodes

destroy:
	kind delete cluster --name $(CLUSTER)
