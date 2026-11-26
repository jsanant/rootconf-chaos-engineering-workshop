# CNPG + Chaos Mesh workshop
#
#   make check              # verify docker + CLIs
#   make cache              # prefetch images/charts (good network)
#   make load               # load cached images into docker/kind
#   make install            # full setup (use OFFLINE=1 after cache)
#   make ui                 # print Grafana + Chaos Mesh URLs
#   make teardown           # delete the kind cluster

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export PATH := $(ROOT)/bin:$(PATH):$(HOME)/.krew/bin

# --- platform ---
OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ifneq ($(filter mingw% msys% cygwin%,$(OS)),)
  OS := windows
endif
ARCH_RAW := $(shell uname -m)
ifeq ($(ARCH_RAW),x86_64)
  ARCH := amd64
else ifeq ($(ARCH_RAW),amd64)
  ARCH := amd64
else ifeq ($(ARCH_RAW),aarch64)
  ARCH := arm64
else ifeq ($(ARCH_RAW),arm64)
  ARCH := arm64
else
  ARCH := $(ARCH_RAW)
endif
ifeq ($(OS)/$(ARCH),darwin/amd64)
  ifeq ($(shell sysctl -in sysctl.proc_translated 2>/dev/null),1)
    ARCH := arm64
  endif
endif
PLATFORM := $(OS)/$(ARCH)

# --- tunables ---
CLUSTER_NAME           ?= cnpg-chaos
KIND_NODE_IMAGE        ?= kindest/node:v1.37.0
KIND_CONFIG            ?= $(ROOT)/kind-config.yaml
OFFLINE                ?= 0
FORCE                  ?= 0
SKIP_MONITORING        ?= 0
LOADGEN_IMAGE          ?= cnpg-loadgen:local
LOADGEN_INTERVAL_MS    ?= 2000
LOADGEN_DOCKER_BUILD   ?= 0

KIND_VERSION           ?= v0.33.0
KUBECTL_VERSION        ?= v1.37.2
HELM_VERSION           ?= v4.3.1
JQ_VERSION             ?= 1.8.1
KIND_MIN_VERSION       ?= 0.33.0

CNPG_CHART_VERSION         ?= 0.29.2
CHAOS_MESH_CHART_VERSION   ?= 2.8.8
MONITORING_CHART_VERSION   ?= 93.11.0

ARTIFACTS      := $(ROOT)/artifacts
IMAGE_CACHE    := $(ARTIFACTS)/images
CHART_CACHE    := $(ARTIFACTS)/charts
BIN_DIR        := $(ROOT)/bin
IMAGES_LIST    := $(ARTIFACTS)/images.txt
# Fixed NodePorts (must match kind-config.yaml extraPortMappings)
GRAFANA_NODEPORT      ?= 30030
CHAOS_DASH_NODEPORT   ?= 32333

HELM_TIMEOUT   ?= 5m
KUBECTL        ?= kubectl
HELM           ?= helm
KIND           ?= kind
DOCKER         ?= docker

.DEFAULT_GOAL := help

.PHONY: help check cache load install ui teardown \
	all setup cache-images cache-charts load-cache install-tools \
	kind monitoring cnpg-operator cnpg-cluster cnpg-plugin chaos-mesh loadgen \
	check-kind wait-nodes wait-cnpg patch-chaos-daemon \
	loadgen-build loadgen-deploy cleanup

# ---------------------------------------------------------------------------
# Public targets
# ---------------------------------------------------------------------------

help:
	@echo "Platform: $(PLATFORM)"
	@echo ""
	@echo "  make check       Check docker and required CLIs"
	@echo "  make cache       Download images + helm charts into artifacts/"
	@echo "  make load        Load cached images into docker (and kind if running)"
	@echo "  make install     Install the full workshop stack + loadgen"
	@echo "                   (after cache: make install OFFLINE=1)"
	@echo "  make ui          Show Grafana + Chaos Mesh URLs (no port-forward)"
	@echo "  make teardown    Delete kind cluster $(CLUSTER_NAME)"
	@echo ""
	@echo "Optional: SKIP_MONITORING=1  FORCE=1 (reinstall tools into ./bin)"

check:
	@echo "Checking prerequisites ($(PLATFORM))..."
	@$(DOCKER) info >/dev/null 2>&1 || { echo "ERROR: start Docker or Rancher Desktop first" >&2; exit 1; }
	@echo "  docker: ok"
	@missing=""; for t in $(KIND) $(KUBECTL) $(HELM) jq; do \
	  command -v $$t >/dev/null || missing="$$missing $$t"; \
	done; \
	if [[ -n "$$missing" ]]; then echo "ERROR: missing:$$missing — run: make install (installs tools)" >&2; exit 1; fi
	@$(MAKE) --no-print-directory check-kind
	@echo "  kubectl/helm/jq: ok"
	@command -v go >/dev/null && echo "  go: ok" || echo "  go: missing (loadgen can use LOADGEN_DOCKER_BUILD=1)"

cache: cache-images cache-charts
	@echo "Cache ready under $(ARTIFACTS)/ — later: make install OFFLINE=1"

load: load-cache
	@echo "Cached images loaded."

install: setup
all: setup

ui:
	@echo "UIs are published via kind extraPortMappings (no port-forward needed):"
	@echo ""
	@echo "  Grafana:     http://localhost:3000   (admin / prom-operator)"
	@echo "  Chaos Mesh:  http://localhost:2333"
	@echo ""
	@echo "If these fail, recreate the cluster (port maps are set at kind create):"
	@echo "  make teardown && make install"

teardown:
	@echo "Deleting kind cluster $(CLUSTER_NAME)..."
	@$(KIND) delete cluster --name $(CLUSTER_NAME) >/dev/null 2>&1 || true
	@echo "Done."

# ---------------------------------------------------------------------------
# Install pipeline (quiet)
# ---------------------------------------------------------------------------

setup: install-tools check kind monitoring cnpg-operator cnpg-cluster cnpg-plugin chaos-mesh loadgen
	@echo ""
	@echo "Install complete."
	@echo "  make ui          — open Grafana + Chaos Mesh"
	@echo "  make teardown    — delete the kind cluster"

check-kind:
	@v=$$($(KIND) version | sed -E 's/^kind v([0-9.]+).*/\1/'); \
	if [[ "$$(printf '%s\n' "$(KIND_MIN_VERSION)" "$$v" | sort -V | head -1)" != "$(KIND_MIN_VERSION)" ]]; then \
	  echo "ERROR: kind v$$v is too old for $(KIND_NODE_IMAGE); need >= v$(KIND_MIN_VERSION). Re-run make install" >&2; exit 1; \
	fi; \
	echo "  kind v$$v: ok"

cache-images:
	@bash $(ROOT)/scripts/cache-images.sh $(IMAGES_LIST)

cache-charts:
	@mkdir -p $(CHART_CACHE)
ifeq ($(OFFLINE),1)
	@echo "OFFLINE=1: refusing to pull charts" >&2; exit 1
endif
	@echo "Caching helm charts..."
	@$(HELM) repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
	@$(HELM) repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
	@$(HELM) repo add chaos-mesh https://charts.chaos-mesh.org >/dev/null 2>&1 || true
	@$(HELM) repo update >/dev/null
	@$(HELM) pull prometheus-community/kube-prometheus-stack --version $(MONITORING_CHART_VERSION) --destination $(CHART_CACHE) >/dev/null
	@$(HELM) pull cnpg/cloudnative-pg --version $(CNPG_CHART_VERSION) --destination $(CHART_CACHE) >/dev/null
	@$(HELM) pull chaos-mesh/chaos-mesh --version $(CHAOS_MESH_CHART_VERSION) --destination $(CHART_CACHE) >/dev/null
	@echo "  charts: $(CHART_CACHE)"

load-cache:
	@IMAGE_CACHE_DIR=$(IMAGE_CACHE) CLUSTER_NAME=$(CLUSTER_NAME) LOAD_KIND=1 \
		bash $(ROOT)/scripts/load-images.sh

kind: check-kind
	@if $(KIND) get clusters 2>/dev/null | grep -qx $(CLUSTER_NAME); then \
		echo "Kind cluster $(CLUSTER_NAME) already exists"; \
	else \
		echo "Creating kind cluster $(CLUSTER_NAME)..."; \
		if [[ "$(OFFLINE)" == "1" ]]; then \
			$(DOCKER) image inspect $(KIND_NODE_IMAGE) >/dev/null 2>&1 || \
			  $(DOCKER) load -i $(IMAGE_CACHE)/$$(echo $(KIND_NODE_IMAGE) | sed -e 's|/|_|g' -e 's|:|__|g').tar >/dev/null; \
		fi; \
		$(KIND) create cluster --name $(CLUSTER_NAME) --image $(KIND_NODE_IMAGE) --config $(KIND_CONFIG) >/dev/null; \
	fi
	@$(MAKE) --no-print-directory wait-nodes
	@if [[ "$(OFFLINE)" == "1" ]]; then $(MAKE) --no-print-directory load-cache; fi

wait-nodes:
	@echo "Waiting for nodes..."
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
	  ready=$$($(KUBECTL) get nodes --no-headers 2>/dev/null | awk '$$2=="Ready"{c++} END{print c+0}'); \
	  if [[ "$$ready" -ge 4 ]]; then echo "  nodes ready ($$ready)"; exit 0; fi; \
	  if [[ "$$i" == "3" ]]; then \
	    for n in $$($(KIND) get nodes --name $(CLUSTER_NAME)); do \
	      $(DOCKER) exec "$$n" sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288 >/dev/null 2>&1 || true; \
	      $(DOCKER) exec "$$n" systemctl restart kubelet >/dev/null 2>&1 || true; \
	    done; \
	  fi; \
	  sleep 5; \
	done; \
	echo "ERROR: nodes not Ready in time" >&2; $(KUBECTL) get nodes; exit 1

monitoring:
ifeq ($(SKIP_MONITORING),1)
	@echo "Skipping monitoring (SKIP_MONITORING=1)"
else
	@echo "Installing monitoring (Prometheus + Grafana)..."
	@if [[ "$(OFFLINE)" == "1" ]]; then \
	  chart=$$(ls $(CHART_CACHE)/kube-prometheus-stack-$(MONITORING_CHART_VERSION).tgz 2>/dev/null | head -1); \
	  [[ -n "$$chart" ]] || { echo "missing chart — run: make cache"; exit 1; }; \
	  $(HELM) upgrade --install monitoring "$$chart" \
	    --namespace monitoring --create-namespace \
	    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
	    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
	    --set grafana.sidecar.dashboards.enabled=true \
	    --set grafana.sidecar.dashboards.label=grafana_dashboard \
	    --set-string grafana.sidecar.dashboards.labelValue=1 \
	    --set grafana.sidecar.dashboards.searchNamespace=ALL \
	    --set grafana.service.type=NodePort \
	    --set grafana.service.nodePort=$(GRAFANA_NODEPORT) \
	    --wait=false --timeout $(HELM_TIMEOUT) >/dev/null; \
	else \
	  $(HELM) repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true; \
	  $(HELM) repo update prometheus-community >/dev/null; \
	  $(HELM) upgrade --install monitoring prometheus-community/kube-prometheus-stack \
	    --namespace monitoring --create-namespace \
	    --version $(MONITORING_CHART_VERSION) \
	    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
	    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
	    --set grafana.sidecar.dashboards.enabled=true \
	    --set grafana.sidecar.dashboards.label=grafana_dashboard \
	    --set-string grafana.sidecar.dashboards.labelValue=1 \
	    --set grafana.sidecar.dashboards.searchNamespace=ALL \
	    --set grafana.service.type=NodePort \
	    --set grafana.service.nodePort=$(GRAFANA_NODEPORT) \
	    --wait=false --timeout $(HELM_TIMEOUT) >/dev/null; \
	fi
	@echo "  monitoring: installed (http://localhost:3000)"
endif

cnpg-operator:
	@echo "Installing CNPG operator..."
	@$(KUBECTL) create namespace monitoring --dry-run=client -o yaml | $(KUBECTL) apply -f - >/dev/null
	@DASHBOARD_ARGS="-f $(ROOT)/manifests/cnpg-operator-values.yaml"; \
	if [[ "$(SKIP_MONITORING)" == "1" ]]; then \
	  DASHBOARD_ARGS="--set monitoring.grafanaDashboard.create=false"; \
	fi; \
	if [[ "$(OFFLINE)" == "1" ]]; then \
	  chart=$$(ls $(CHART_CACHE)/cloudnative-pg-$(CNPG_CHART_VERSION).tgz | head -1); \
	  $(HELM) upgrade --install cnpg "$$chart" \
	    --namespace cnpg-system --create-namespace \
	    $$DASHBOARD_ARGS \
	    --wait=false --timeout $(HELM_TIMEOUT) >/dev/null; \
	else \
	  $(HELM) repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true; \
	  $(HELM) repo update cnpg >/dev/null; \
	  $(HELM) upgrade --install cnpg cnpg/cloudnative-pg \
	    --namespace cnpg-system --create-namespace \
	    --version $(CNPG_CHART_VERSION) \
	    $$DASHBOARD_ARGS \
	    --wait=false --timeout $(HELM_TIMEOUT) >/dev/null; \
	fi
	@$(KUBECTL) -n cnpg-system rollout status deploy/cnpg-cloudnative-pg --timeout=180s >/dev/null
	@echo "  cnpg operator: ready"

cnpg-cluster:
	@echo "Creating CNPG cluster (sync replication)..."
	@$(KUBECTL) apply -f $(ROOT)/manifests/pg-cluster.yaml >/dev/null
	@$(MAKE) --no-print-directory wait-cnpg

wait-cnpg:
	@echo "Waiting for pg-cluster to become Ready..."
	@$(KUBECTL) wait --for=condition=Ready cluster/pg-cluster --timeout=300s >/dev/null
	@echo "  pg-cluster: ready ($$($(KUBECTL) get pods -l cnpg.io/cluster=pg-cluster --no-headers 2>/dev/null | wc -l | tr -d ' ') instances)"

cnpg-plugin:
	@export PATH="$(HOME)/.krew/bin:$$PATH"; \
	if $(KUBECTL) krew >/dev/null 2>&1; then \
	  $(KUBECTL) krew install cnpg >/dev/null 2>&1 || $(KUBECTL) krew upgrade cnpg >/dev/null 2>&1 || true; \
	  echo "  kubectl cnpg: ok"; \
	else \
	  echo "  kubectl cnpg: skipped (krew not installed)"; \
	fi

chaos-mesh:
	@echo "Installing Chaos Mesh..."
	@$(KUBECTL) create namespace chaos-mesh --dry-run=client -o yaml | $(KUBECTL) apply -f - >/dev/null
	@if [[ "$(OFFLINE)" == "1" ]]; then \
	  chart=$$(ls $(CHART_CACHE)/chaos-mesh-$(CHAOS_MESH_CHART_VERSION).tgz | head -1); \
	  $(HELM) upgrade --install chaos-mesh "$$chart" \
	    --namespace chaos-mesh \
	    --set chaosDaemon.runtime=containerd \
	    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
	    --set dashboard.create=true \
	    --set dashboard.service.type=NodePort \
	    --set dashboard.service.nodePort=$(CHAOS_DASH_NODEPORT) \
	    --set controllerManager.replicaCount=1 \
	    --set chaosDaemon.tolerations[0].key=node-role.kubernetes.io/control-plane \
	    --set chaosDaemon.tolerations[0].operator=Exists \
	    --set chaosDaemon.tolerations[0].effect=NoSchedule \
	    --set chaosDaemon.tolerations[1].key=node-role.kubernetes.io/master \
	    --set chaosDaemon.tolerations[1].operator=Exists \
	    --set chaosDaemon.tolerations[1].effect=NoSchedule \
	    --wait=false --timeout $(HELM_TIMEOUT) >/dev/null; \
	else \
	  $(HELM) repo add chaos-mesh https://charts.chaos-mesh.org >/dev/null 2>&1 || true; \
	  $(HELM) repo update chaos-mesh >/dev/null; \
	  $(HELM) upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
	    --namespace chaos-mesh \
	    --version $(CHAOS_MESH_CHART_VERSION) \
	    --set chaosDaemon.runtime=containerd \
	    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
	    --set dashboard.create=true \
	    --set dashboard.service.type=NodePort \
	    --set dashboard.service.nodePort=$(CHAOS_DASH_NODEPORT) \
	    --set controllerManager.replicaCount=1 \
	    --set 'chaosDaemon.tolerations[0].key=node-role.kubernetes.io/control-plane' \
	    --set 'chaosDaemon.tolerations[0].operator=Exists' \
	    --set 'chaosDaemon.tolerations[0].effect=NoSchedule' \
	    --set 'chaosDaemon.tolerations[1].key=node-role.kubernetes.io/master' \
	    --set 'chaosDaemon.tolerations[1].operator=Exists' \
	    --set 'chaosDaemon.tolerations[1].effect=NoSchedule' \
	    --wait=false --timeout $(HELM_TIMEOUT) >/dev/null; \
	fi
	@$(MAKE) --no-print-directory patch-chaos-daemon
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
	  ready=$$($(KUBECTL) -n chaos-mesh get pods -l app.kubernetes.io/component=chaos-daemon --no-headers 2>/dev/null | awk '$$2 ~ /^1\/1$$/ && $$3=="Running"{c++} END{print c+0}'); \
	  [[ "$$ready" -ge 3 ]] && echo "  chaos-mesh: ready (http://localhost:2333)" && exit 0; \
	  sleep 5; \
	done; \
	echo "ERROR: chaos-daemon not ready" >&2; exit 1

patch-chaos-daemon:
	@$(KUBECTL) -n chaos-mesh patch ds chaos-daemon --type='json' -p='[{"op":"replace","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]}]' >/dev/null 2>&1 || true

loadgen: loadgen-build loadgen-deploy
	@echo "  loadgen: ready"

loadgen-build:
	@mkdir -p $(IMAGE_CACHE)
ifeq ($(LOADGEN_DOCKER_BUILD),1)
	@$(DOCKER) build -f $(ROOT)/loadgen/Dockerfile.golang \
	  --build-arg TARGETOS=linux \
	  --build-arg TARGETARCH=$(ARCH) \
	  -t $(LOADGEN_IMAGE) \
	  $(ROOT)/loadgen >/dev/null
else
	@command -v go >/dev/null || { echo "Go required for loadgen (or LOADGEN_DOCKER_BUILD=1)"; exit 1; }
	@echo "Building loadgen..."
	@ctx=$$(mktemp -d); trap 'rm -rf "$$ctx"' EXIT; \
	cd $(ROOT)/loadgen && \
	GOOS=linux GOARCH=$(ARCH) CGO_ENABLED=0 \
	  go build -trimpath -ldflags='-s -w' -o "$$ctx/loadgen" . && \
	cp $(ROOT)/loadgen/Dockerfile "$$ctx/Dockerfile" && \
	$(DOCKER) build -t $(LOADGEN_IMAGE) "$$ctx" >/dev/null
endif
	@$(KIND) load docker-image $(LOADGEN_IMAGE) --name $(CLUSTER_NAME) >/dev/null
	@$(DOCKER) save -o $(IMAGE_CACHE)/cnpg-loadgen__local.tar $(LOADGEN_IMAGE) >/dev/null

loadgen-deploy:
	@sed -e 's|image: cnpg-loadgen:local|image: $(LOADGEN_IMAGE)|' \
	    -e 's|value: "2000"|value: "$(LOADGEN_INTERVAL_MS)"|' \
	    $(ROOT)/loadgen/k8s/deployment.yaml | $(KUBECTL) apply -f - >/dev/null
	@$(KUBECTL) -n default rollout status deploy/cnpg-loadgen --timeout=180s >/dev/null

install-tools:
	@BIN_DIR=$(BIN_DIR) OS=$(OS) ARCH=$(ARCH) \
	  KIND_VERSION=$(KIND_VERSION) KUBECTL_VERSION=$(KUBECTL_VERSION) \
	  HELM_VERSION=$(HELM_VERSION) JQ_VERSION=$(JQ_VERSION) FORCE=$(FORCE) \
	  bash $(ROOT)/scripts/install-tools.sh

cleanup:
	@$(KUBECTL) delete podchaos,networkchaos,iochaos,stresschaos,timechaos,dnschaos,httpchaos,jvmchaos,workflow,schedule \
	  --all -A --wait=false >/dev/null 2>&1 || true
	@$(KUBECTL) delete -f $(ROOT)/loadgen/k8s/deployment.yaml --ignore-not-found --wait=false >/dev/null 2>&1 || true
	@$(KUBECTL) delete -f $(ROOT)/manifests/pg-cluster.yaml --ignore-not-found --wait=false >/dev/null 2>&1 || true
	@$(HELM) uninstall chaos-mesh -n chaos-mesh >/dev/null 2>&1 || true
	@$(HELM) uninstall cnpg -n cnpg-system >/dev/null 2>&1 || true
	@$(HELM) uninstall monitoring -n monitoring >/dev/null 2>&1 || true
	@$(KUBECTL) delete namespace chaos-mesh cnpg-system monitoring --wait=false >/dev/null 2>&1 || true
	@echo "Workshop apps removed (kind cluster kept)."
