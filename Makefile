# CNPG + Chaos Mesh workshop — platform-aware setup
#
# Quick start:
#   make platform          # show detected OS/ARCH
#   make all               # full online setup + loadgen
#   make all OFFLINE=1     # use artifacts/ cache (images + helm charts)
#   make cache             # prefetch images/charts while network is good
#   make help
#
# Individual steps: kind | monitoring | cnpg-operator | cnpg-cluster |
#                   cnpg-plugin | chaos-mesh | loadgen | status | cleanup | teardown

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export PATH := $(ROOT)/bin:$(PATH):$(HOME)/.krew/bin

# --- platform (darwin|linux|windows × amd64|arm64) ---
OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
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
PLATFORM := $(OS)/$(ARCH)

# Windows tip: run make from Git Bash or WSL; Chocolatey installs are also fine on PATH.
ifeq ($(OS),msys)
  OS := windows
endif
ifeq ($(OS),mingw64_nt-10.0)
  OS := windows
endif

# --- tunables ---
CLUSTER_NAME           ?= cnpg-chaos
KIND_NODE_IMAGE        ?= kindest/node:v1.37.0
KIND_CONFIG            ?= $(ROOT)/kind-config.yaml
OFFLINE                ?= 0
SKIP_MONITORING        ?= 0
LOADGEN_IMAGE          ?= cnpg-loadgen:local
LOADGEN_INTERVAL_MS    ?= 2000

CNPG_CHART_VERSION         ?= 0.29.2
CHAOS_MESH_CHART_VERSION   ?= 2.8.8
MONITORING_CHART_VERSION   ?= 93.11.0

ARTIFACTS      := $(ROOT)/artifacts
IMAGE_CACHE    := $(ARTIFACTS)/images
CHART_CACHE    := $(ARTIFACTS)/charts
BIN_DIR        := $(ROOT)/bin
IMAGES_LIST    := $(ARTIFACTS)/images.txt

HELM_TIMEOUT   ?= 5m
KUBECTL        ?= kubectl
HELM           ?= helm
KIND           ?= kind
DOCKER         ?= docker

.DEFAULT_GOAL := help

.PHONY: help platform doctor all setup cache cache-images cache-charts load-cache \
	kind monitoring cnpg-operator cnpg-grafana-dashboard cnpg-cluster cnpg-plugin chaos-mesh \
	loadgen loadgen-build loadgen-deploy loadgen-logs status cleanup teardown \
	install-tools wait-nodes wait-cnpg patch-chaos-daemon

help:
	@echo "Platform: $(PLATFORM)   OFFLINE=$(OFFLINE)   SKIP_MONITORING=$(SKIP_MONITORING)"
	@echo ""
	@echo "Setup:"
	@echo "  make all                 Full stack + loadgen (set OFFLINE=1 to use cache)"
	@echo "  make kind                Create kind cluster $(CLUSTER_NAME)"
	@echo "  make monitoring          kube-prometheus-stack (SKIP_MONITORING=1 to skip)"
	@echo "  make cnpg-operator       Install CloudNativePG operator (+ Grafana CNPG dashboard)"
	@echo "  make cnpg-grafana-dashboard  Verify CNPG dashboard ConfigMap in monitoring"
	@echo "  make cnpg-cluster        Create 3-instance pg-cluster"
	@echo "  make cnpg-plugin         Install kubectl cnpg via krew"
	@echo "  make chaos-mesh          Install Chaos Mesh + control-plane daemon tolerations"
	@echo "  make loadgen             Build, load into kind, deploy R/W loadgen"
	@echo "  make status              Show cluster / CNPG / loadgen status"
	@echo "  make cleanup             Remove chaos CRs, loadgen, helm apps (keep kind cluster)"
	@echo "  make teardown            cleanup + delete kind cluster $(CLUSTER_NAME)"
	@echo ""
	@echo "Offline / poor network:"
	@echo "  make cache               Prefetch container images + helm charts into artifacts/"
	@echo "  make cache-images        Prefetch/save docker images only"
	@echo "  make cache-charts        Prefetch helm chart tgz only"
	@echo "  make load-cache          docker load + kind load from artifacts/images"
	@echo "  make all OFFLINE=1       Install using cached charts/images (no helm repo update)"
	@echo ""
	@echo "Loadgen:"
	@echo "  make loadgen-build       docker build $(LOADGEN_IMAGE) for linux/$(ARCH)"
	@echo "  make loadgen-deploy      Apply k8s manifests"
	@echo "  make loadgen-logs        Tail loadgen logs"
	@echo ""
	@echo "Tools:"
	@echo "  make platform            Print detected OS/ARCH"
	@echo "  make doctor              Check docker/kind/kubectl/helm/go"
	@echo "  make install-tools       Download kind+kubectl into ./bin for $(PLATFORM)"

platform:
	@bash $(ROOT)/scripts/platform.sh

doctor:
	@echo "Platform: $(PLATFORM)"
	@$(DOCKER) version --format 'docker: {{.Server.Version}}' 2>/dev/null || echo "docker: MISSING"
	@$(KIND) version 2>/dev/null || echo "kind: MISSING (make install-tools)"
	@$(KUBECTL) version --client --output=yaml 2>/dev/null | head -3 || echo "kubectl: MISSING"
	@$(HELM) version --short 2>/dev/null || echo "helm: MISSING"
	@command -v go >/dev/null && go version || echo "go: optional (image build uses golang container)"
	@command -v jq >/dev/null && jq --version || echo "jq: recommended"
	@echo "OFFLINE=$(OFFLINE) IMAGE_CACHE=$(IMAGE_CACHE) CHART_CACHE=$(CHART_CACHE)"

# ---------------------------------------------------------------------------
# Offline cache
# ---------------------------------------------------------------------------

cache: cache-images cache-charts
	@echo "Cache ready under $(ARTIFACTS)"
	@echo "Later: make all OFFLINE=1"

cache-images:
	@bash $(ROOT)/scripts/cache-images.sh $(IMAGES_LIST)

cache-charts:
	@mkdir -p $(CHART_CACHE)
ifeq ($(OFFLINE),1)
	@echo "OFFLINE=1: refusing to pull charts from the network" >&2; exit 1
endif
	@$(HELM) repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	@$(HELM) repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
	@$(HELM) repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
	@$(HELM) repo update
	@$(HELM) pull prometheus-community/kube-prometheus-stack --version $(MONITORING_CHART_VERSION) --destination $(CHART_CACHE)
	@$(HELM) pull cnpg/cloudnative-pg --version $(CNPG_CHART_VERSION) --destination $(CHART_CACHE)
	@$(HELM) pull chaos-mesh/chaos-mesh --version $(CHAOS_MESH_CHART_VERSION) --destination $(CHART_CACHE)
	@ls -la $(CHART_CACHE)

load-cache:
	@IMAGE_CACHE_DIR=$(IMAGE_CACHE) CLUSTER_NAME=$(CLUSTER_NAME) LOAD_KIND=1 \
		bash $(ROOT)/scripts/load-images.sh

# ---------------------------------------------------------------------------
# Full pipeline
# ---------------------------------------------------------------------------

all: setup
setup: doctor kind monitoring cnpg-operator cnpg-cluster cnpg-plugin chaos-mesh loadgen status
	@echo "Setup complete."

# ---------------------------------------------------------------------------
# Kind
# ---------------------------------------------------------------------------

kind:
	@if $(KIND) get clusters 2>/dev/null | grep -qx $(CLUSTER_NAME); then \
		echo "kind cluster $(CLUSTER_NAME) already exists"; \
	else \
		if [[ "$(OFFLINE)" == "1" ]]; then \
			echo "OFFLINE: ensuring node image present locally"; \
			$(DOCKER) image inspect $(KIND_NODE_IMAGE) >/dev/null 2>&1 || \
			  $(DOCKER) load -i $(IMAGE_CACHE)/$$(echo $(KIND_NODE_IMAGE) | sed -e 's|/|_|g' -e 's|:|__|g').tar; \
		fi; \
		$(KIND) create cluster --name $(CLUSTER_NAME) --image $(KIND_NODE_IMAGE) --config $(KIND_CONFIG); \
	fi
	@$(MAKE) wait-nodes
	@if [[ "$(OFFLINE)" == "1" ]]; then $(MAKE) load-cache; fi

wait-nodes:
	@echo "Waiting for nodes Ready..."
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
	  ready=$$($(KUBECTL) get nodes --no-headers 2>/dev/null | awk '$$2=="Ready"{c++} END{print c+0}'); \
	  echo "  ready_nodes=$$ready"; \
	  if [[ "$$ready" -ge 4 ]]; then exit 0; fi; \
	  # kind sometimes needs inotify bump on busy hosts \
	  if [[ "$$i" == "3" ]]; then \
	    for n in $$($(KIND) get nodes --name $(CLUSTER_NAME)); do \
	      $(DOCKER) exec "$$n" sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288 >/dev/null 2>&1 || true; \
	      $(DOCKER) exec "$$n" systemctl restart kubelet >/dev/null 2>&1 || true; \
	    done; \
	  fi; \
	  sleep 5; \
	done; \
	echo "ERROR: nodes not Ready in time" >&2; $(KUBECTL) get nodes; exit 1

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

monitoring:
ifeq ($(SKIP_MONITORING),1)
	@echo "SKIP_MONITORING=1"
else
	@if [[ "$(OFFLINE)" == "1" ]]; then \
	  chart=$$(ls $(CHART_CACHE)/kube-prometheus-stack-$(MONITORING_CHART_VERSION).tgz 2>/dev/null | head -1); \
	  [[ -n "$$chart" ]] || { echo "missing $$chart — run: make cache-charts"; exit 1; }; \
	  $(HELM) upgrade --install monitoring "$$chart" \
	    --namespace monitoring --create-namespace \
	    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
	    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
	    --set grafana.sidecar.dashboards.enabled=true \
	    --set grafana.sidecar.dashboards.label=grafana_dashboard \
	    --set grafana.sidecar.dashboards.labelValue=1 \
	    --set grafana.sidecar.dashboards.searchNamespace=ALL \
	    --wait=false --timeout $(HELM_TIMEOUT); \
	else \
	  $(HELM) repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true; \
	  $(HELM) repo update prometheus-community; \
	  $(HELM) upgrade --install monitoring prometheus-community/kube-prometheus-stack \
	    --namespace monitoring --create-namespace \
	    --version $(MONITORING_CHART_VERSION) \
	    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
	    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
	    --set grafana.sidecar.dashboards.enabled=true \
	    --set grafana.sidecar.dashboards.label=grafana_dashboard \
	    --set grafana.sidecar.dashboards.labelValue=1 \
	    --set grafana.sidecar.dashboards.searchNamespace=ALL \
	    --wait=false --timeout $(HELM_TIMEOUT); \
	fi
	@echo "monitoring installed (pods may still be pulling/starting)"
endif

# ---------------------------------------------------------------------------
# CNPG
# ---------------------------------------------------------------------------

cnpg-operator:
	@# Dashboard ConfigMap is created in namespace monitoring — ensure it exists.
	@$(KUBECTL) create namespace monitoring --dry-run=client -o yaml | $(KUBECTL) apply -f -
	@DASHBOARD_ARGS="-f $(ROOT)/manifests/cnpg-operator-values.yaml"; \
	if [[ "$(SKIP_MONITORING)" == "1" ]]; then \
	  DASHBOARD_ARGS="--set monitoring.grafanaDashboard.create=false"; \
	  echo "SKIP_MONITORING=1: not provisioning CNPG Grafana dashboard"; \
	fi; \
	if [[ "$(OFFLINE)" == "1" ]]; then \
	  chart=$$(ls $(CHART_CACHE)/cloudnative-pg-$(CNPG_CHART_VERSION).tgz | head -1); \
	  $(HELM) upgrade --install cnpg "$$chart" \
	    --namespace cnpg-system --create-namespace \
	    $$DASHBOARD_ARGS \
	    --wait=false --timeout $(HELM_TIMEOUT); \
	else \
	  $(HELM) repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true; \
	  $(HELM) repo update cnpg; \
	  $(HELM) upgrade --install cnpg cnpg/cloudnative-pg \
	    --namespace cnpg-system --create-namespace \
	    --version $(CNPG_CHART_VERSION) \
	    $$DASHBOARD_ARGS \
	    --wait=false --timeout $(HELM_TIMEOUT); \
	fi
	@$(KUBECTL) -n cnpg-system rollout status deploy/cnpg-cloudnative-pg --timeout=180s
	@if [[ "$(SKIP_MONITORING)" != "1" ]]; then $(MAKE) cnpg-grafana-dashboard; fi

# Ensure dashboard ConfigMap landed in monitoring (sidecar picks up grafana_dashboard=1)
cnpg-grafana-dashboard:
	@echo "CNPG Grafana dashboard ConfigMap:"
	@$(KUBECTL) -n monitoring get configmap cnpg-grafana-dashboard -o wide 2>/dev/null || \
	  { echo "WARN: cnpg-grafana-dashboard missing in monitoring — was monitoring installed?"; exit 0; }

cnpg-cluster:
	@$(KUBECTL) apply -f $(ROOT)/manifests/pg-cluster.yaml
	@$(MAKE) wait-cnpg

wait-cnpg:
	@echo "Waiting for Cluster/pg-cluster Ready..."
	@$(KUBECTL) wait --for=condition=Ready cluster/pg-cluster --timeout=300s
	@$(KUBECTL) get pods -l cnpg.io/cluster=pg-cluster -o wide

cnpg-plugin:
	@export PATH="$(HOME)/.krew/bin:$$PATH"; \
	if $(KUBECTL) krew 2>/dev/null | head -1 >/dev/null; then \
	  $(KUBECTL) krew install cnpg 2>/dev/null || $(KUBECTL) krew upgrade cnpg || true; \
	  $(KUBECTL) cnpg status pg-cluster || true; \
	else \
	  echo "WARN: krew not installed — skip cnpg plugin (see Setup.md)"; \
	fi

# ---------------------------------------------------------------------------
# Chaos Mesh
# ---------------------------------------------------------------------------

chaos-mesh:
	@$(KUBECTL) create namespace chaos-mesh --dry-run=client -o yaml | $(KUBECTL) apply -f -
	@if [[ "$(OFFLINE)" == "1" ]]; then \
	  chart=$$(ls $(CHART_CACHE)/chaos-mesh-$(CHAOS_MESH_CHART_VERSION).tgz | head -1); \
	  $(HELM) upgrade --install chaos-mesh "$$chart" \
	    --namespace chaos-mesh \
	    --set chaosDaemon.runtime=containerd \
	    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
	    --set dashboard.create=true \
	    --set controllerManager.replicaCount=1 \
	    --set chaosDaemon.tolerations[0].key=node-role.kubernetes.io/control-plane \
	    --set chaosDaemon.tolerations[0].operator=Exists \
	    --set chaosDaemon.tolerations[0].effect=NoSchedule \
	    --set chaosDaemon.tolerations[1].key=node-role.kubernetes.io/master \
	    --set chaosDaemon.tolerations[1].operator=Exists \
	    --set chaosDaemon.tolerations[1].effect=NoSchedule \
	    --wait=false --timeout $(HELM_TIMEOUT); \
	else \
	  $(HELM) repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true; \
	  $(HELM) repo update chaos-mesh; \
	  $(HELM) upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
	    --namespace chaos-mesh \
	    --version $(CHAOS_MESH_CHART_VERSION) \
	    --set chaosDaemon.runtime=containerd \
	    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
	    --set dashboard.create=true \
	    --set controllerManager.replicaCount=1 \
	    --set 'chaosDaemon.tolerations[0].key=node-role.kubernetes.io/control-plane' \
	    --set 'chaosDaemon.tolerations[0].operator=Exists' \
	    --set 'chaosDaemon.tolerations[0].effect=NoSchedule' \
	    --set 'chaosDaemon.tolerations[1].key=node-role.kubernetes.io/master' \
	    --set 'chaosDaemon.tolerations[1].operator=Exists' \
	    --set 'chaosDaemon.tolerations[1].effect=NoSchedule' \
	    --wait=false --timeout $(HELM_TIMEOUT); \
	fi
	@$(MAKE) patch-chaos-daemon
	@echo "Waiting for chaos-daemon..."
	@for i in 1 2 3 4 5 6 7 8 9 10 11 12; do \
	  ready=$$($(KUBECTL) -n chaos-mesh get pods -l app.kubernetes.io/component=chaos-daemon --no-headers 2>/dev/null | awk '$$2 ~ /^1\/1$$/ && $$3=="Running"{c++} END{print c+0}'); \
	  echo "  chaos-daemons_ready=$$ready"; \
	  [[ "$$ready" -ge 3 ]] && exit 0; \
	  sleep 5; \
	done; \
	$(KUBECTL) -n chaos-mesh get pods -o wide; exit 1

# zsh-safe fallback if helm --set arrays were stripped by a calling shell
patch-chaos-daemon:
	@$(KUBECTL) -n chaos-mesh patch ds chaos-daemon --type='json' -p='[{"op":"replace","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]}]' 2>/dev/null || true

# ---------------------------------------------------------------------------
# Loadgen (Go R/W client)
# ---------------------------------------------------------------------------

loadgen: loadgen-build loadgen-deploy

# Cross-compile on the host (needs local Go + modules), then pack into scratch.
# Set LOADGEN_DOCKER_BUILD=1 to use Dockerfile.golang instead (needs clean registry TLS).
LOADGEN_DOCKER_BUILD ?= 0

loadgen-build:
	@mkdir -p $(IMAGE_CACHE)
ifeq ($(LOADGEN_DOCKER_BUILD),1)
	@$(DOCKER) build -f $(ROOT)/loadgen/Dockerfile.golang \
	  --build-arg TARGETOS=linux \
	  --build-arg TARGETARCH=$(ARCH) \
	  -t $(LOADGEN_IMAGE) \
	  $(ROOT)/loadgen
else
	@command -v go >/dev/null || { echo "Go required for loadgen-build (or set LOADGEN_DOCKER_BUILD=1)"; exit 1; }
	@echo "Building loadgen for linux/$(ARCH) with local Go..."
	@cd $(ROOT)/loadgen && \
	  GOOS=linux GOARCH=$(ARCH) CGO_ENABLED=0 \
	  go build -trimpath -ldflags='-s -w' -o loadgen .
	@$(DOCKER) build -f $(ROOT)/loadgen/Dockerfile -t $(LOADGEN_IMAGE) $(ROOT)/loadgen
	@rm -f $(ROOT)/loadgen/loadgen
endif
	@$(KIND) load docker-image $(LOADGEN_IMAGE) --name $(CLUSTER_NAME)
	@$(DOCKER) save -o $(IMAGE_CACHE)/cnpg-loadgen__local.tar $(LOADGEN_IMAGE)

loadgen-deploy:
	@sed -e 's|image: cnpg-loadgen:local|image: $(LOADGEN_IMAGE)|' \
	    -e 's|value: "2000"|value: "$(LOADGEN_INTERVAL_MS)"|' \
	    $(ROOT)/loadgen/k8s/deployment.yaml | $(KUBECTL) apply -f -
	@$(KUBECTL) -n default rollout status deploy/cnpg-loadgen --timeout=180s
	@$(KUBECTL) -n default get pods -l app=cnpg-loadgen -o wide

loadgen-logs:
	@$(KUBECTL) -n default logs -l app=cnpg-loadgen --tail=50 -f

# ---------------------------------------------------------------------------
# Status / cleanup / teardown
# ---------------------------------------------------------------------------

status:
	@echo "=== nodes ==="; $(KUBECTL) get nodes -o wide || true
	@echo "=== cnpg ==="; $(KUBECTL) get cluster pg-cluster -o wide 2>/dev/null || true
	@$(KUBECTL) get pods -l cnpg.io/cluster=pg-cluster -o wide 2>/dev/null || true
	@echo "=== loadgen ==="; $(KUBECTL) get pods -l app=cnpg-loadgen -o wide 2>/dev/null || true
	@echo "=== chaos-mesh ==="; $(KUBECTL) -n chaos-mesh get pods -o wide 2>/dev/null || true
	@command -v kubectl >/dev/null && $(KUBECTL) cnpg status pg-cluster 2>/dev/null || true

# Soft cleanup: drop workshop workloads/releases, keep the kind cluster for a fast re-setup.
cleanup:
	@echo "==> Deleting Chaos Mesh experiment CRs..."
	@$(KUBECTL) delete podchaos,networkchaos,iochaos,stresschaos,timechaos,dnschaos,httpchaos,jvmchaos,workflow,schedule \
	  --all -A --wait=false 2>/dev/null || true
	@echo "==> Deleting loadgen..."
	@$(KUBECTL) delete -f $(ROOT)/loadgen/k8s/deployment.yaml --ignore-not-found --wait=false 2>/dev/null || true
	@echo "==> Deleting CNPG cluster..."
	@$(KUBECTL) delete -f $(ROOT)/manifests/pg-cluster.yaml --ignore-not-found --wait=false 2>/dev/null || true
	@$(KUBECTL) delete cluster pg-cluster --ignore-not-found --wait=false 2>/dev/null || true
	@echo "==> Uninstalling Helm releases..."
	@$(HELM) uninstall chaos-mesh -n chaos-mesh 2>/dev/null || true
	@$(HELM) uninstall cnpg -n cnpg-system 2>/dev/null || true
	@$(HELM) uninstall monitoring -n monitoring 2>/dev/null || true
	@echo "==> Deleting workshop namespaces (best-effort)..."
	@$(KUBECTL) delete namespace chaos-mesh cnpg-system monitoring --wait=false 2>/dev/null || true
	@# CNPG Grafana dashboard ConfigMap lives in monitoring; gone with the ns.
	@echo "==> Waiting briefly for Cluster CR finalizers..."
	@sleep 5
	@$(KUBECTL) get cluster,pods -A 2>/dev/null | head -40 || true
	@echo "Cleanup done (kind cluster $(CLUSTER_NAME) kept). Re-run: make monitoring cnpg-operator cnpg-cluster chaos-mesh loadgen"
	@echo "Full wipe: make teardown"

# Hard cleanup: soft cleanup is unnecessary once the kind cluster is deleted.
teardown:
	@echo "==> Deleting kind cluster $(CLUSTER_NAME)..."
	@$(KIND) delete cluster --name $(CLUSTER_NAME) || true
	@echo "Teardown done."

# ---------------------------------------------------------------------------
# Optional: download kind + kubectl into ./bin for this platform
# ---------------------------------------------------------------------------

KIND_VERSION    ?= v0.33.0
KUBECTL_VERSION ?= v1.37.2

install-tools:
	@mkdir -p $(BIN_DIR)
	@echo "Installing tools for $(PLATFORM) into $(BIN_DIR)"
ifeq ($(OS),darwin)
	@echo "On macOS, prefer: brew install kind kubectl helm krew jq"
endif
	@echo "Downloading kind $(KIND_VERSION)..."
	@curl -fsSL -o $(BIN_DIR)/kind \
	  "https://kind.sigs.k8s.io/dl/$(KIND_VERSION)/kind-$(OS)-$(ARCH)"
	@chmod +x $(BIN_DIR)/kind
	@echo "Downloading kubectl $(KUBECTL_VERSION)..."
	@curl -fsSL -o $(BIN_DIR)/kubectl \
	  "https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/$(OS)/$(ARCH)/kubectl"
	@chmod +x $(BIN_DIR)/kubectl
	@$(BIN_DIR)/kind version; $(BIN_DIR)/kubectl version --client
	@echo "Add to PATH: export PATH=$(BIN_DIR):$$PATH"
	@echo "Helm: install via https://helm.sh/docs/intro/install/ (brew/choco/script)"
