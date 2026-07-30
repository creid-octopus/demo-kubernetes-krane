.PHONY: cluster-up cluster-down build load deploy-dev deploy-us deploy-eu fan-out logs clean

IMAGE_REPO ?= demo-kubernetes-krane-app
# := (not ?=) — this must be a simply-expanded variable, evaluated exactly
# once. With ?=/= (recursive expansion), $(shell date +%s) reruns on every
# reference to $(REVISION), so `build` and `load` would tag/load two
# different timestamps in the same invocation. A command-line override
# (make deploy-dev REVISION=1.0.1) still takes precedence over this default
# either way.
REVISION   := dev-$(shell date +%s)
CONTEXT    ?= kind-demo-krane

cluster-up:
	hack/local-cluster.sh up

cluster-down:
	hack/local-cluster.sh down

build:
	docker build --target debug -t $(IMAGE_REPO):$(REVISION) app/

load: build
	kind load docker-image $(IMAGE_REPO):$(REVISION) --name demo-krane

deploy-dev: load
	scripts/deploy.sh k8s/bindings/development.env $(CONTEXT) $(REVISION) $(IMAGE_REPO)

deploy-us: load
	scripts/deploy.sh k8s/bindings/us.env $(CONTEXT) $(REVISION) $(IMAGE_REPO)

deploy-eu: load
	scripts/deploy.sh k8s/bindings/eu.env $(CONTEXT) $(REVISION) $(IMAGE_REPO)

fan-out: load
	scripts/fan-out.sh $(REVISION) scripts/regions.conf $(IMAGE_REPO)

logs:
	kubectl --context $(CONTEXT) -n app-development logs -l app=demo-app -f --all-containers

clean: cluster-down
