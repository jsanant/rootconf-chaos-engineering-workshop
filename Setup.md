# Workshop Setup — Install Steps

> **Preferred:** from the repo root, use the Makefile:
>
> ```bash
> make check          # verify docker + CLIs
> make cache          # optional — while network is good
> make install        # or: make install OFFLINE=1
> make ui             # Grafana + Chaos Mesh dashboards
> ```
>
> Manual commands below remain valid if you prefer copy-paste setup.

> Run all commands in a terminal. You need a running container runtime first
> (Docker Desktop or Rancher Desktop), then the CLI tools below.

## 0. Prerequisites

### Container runtime

Install and start one of these (make sure it's running before step 1):

- Docker Desktop — [https://www.docker.com/products/docker-desktop/](https://www.docker.com/products/docker-desktop/)
  - Direct downloads: [macOS](https://docs.docker.com/desktop/setup/install/mac-install/) · [Windows](https://docs.docker.com/desktop/setup/install/windows-install/) · [Linux](https://docs.docker.com/desktop/setup/install/linux/)
- Rancher Desktop (alternative) — [https://rancherdesktop.io/](https://rancherdesktop.io/)

> Give it at least **4 CPUs and 8 GB RAM** (Settings → Resources). The chaos +  
> monitoring + Postgres pods need the headroom.



### CLI tools

Install `kind`, `kubectl`, `helm`, `krew`, and `jq`. Pick your OS.

### macOS

```bash
# Requires Homebrew: https://brew.sh
brew install kind kubectl helm krew jq
```



### Windows

```powershell
# Requires Chocolatey (run PowerShell as Administrator): https://chocolatey.org/install
choco install kind kubernetes-cli kubernetes-helm krew jq -y
```

> Tip: Use the **WSL 2** backend in Docker/Rancher Desktop. You can also run the
> macOS/Linux steps from inside a WSL 2 Ubuntu shell if you prefer.



### Linux

```bash
# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# kubectl
curl -LO "https://dl.k8s.io/release/v1.37.2/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/kubectl

# helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# jq
sudo apt-get update && sudo apt-get install -y jq

# krew
(
  set -x; cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" && ./"${KREW}" install krew
)
```

> `krew` needs `$HOME/.krew/bin` on your `PATH`. Add this to your shell profile and restart the shell:
>
> ```bash
> export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
> ```

Check everything is on your `PATH`:

```bash
kind version && kubectl version --client && helm version && kubectl krew version && jq --version
```

---



## 1. Kind cluster (3 worker nodes)

> Creates one control-plane plus three workers so pods can be spread across nodes
> for realistic chaos experiments.

```bash
cat > kind-config.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
EOF

kind create cluster --name cnpg-chaos --image kindest/node:v1.37.0 --config kind-config.yaml
kubectl get nodes   # expect 4 nodes: 1 control-plane + 3 workers
```
#### Windows
```powershell
@'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
'@ | Set-Content -Path kind-config.yaml -Encoding utf8
```


## 2. Grafana + Prometheus

> Installs the kube-prometheus-stack (Prometheus Operator + Grafana). The two
> `*SelectorNilUsesHelmValues=false` flags let Prometheus discover the CNPG
> cluster's PodMonitor in step 4.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.sidecar.dashboards.enabled=true \
  --set grafana.sidecar.dashboards.label=grafana_dashboard \
  --set grafana.sidecar.dashboards.labelValue=1 \
  --set grafana.sidecar.dashboards.searchNamespace=ALL
```
#### Windows
```powershell
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack `
  --namespace monitoring --create-namespace `
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false `
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false `
  --set grafana.sidecar.dashboards.enabled=true `
  --set grafana.sidecar.dashboards.label=grafana_dashboard `
  --set-string grafana.sidecar.dashboards.labelValue=1 `
  --set grafana.sidecar.dashboards.searchNamespace=ALL

kubectl --namespace monitoring port-forward svc/monitoring-grafana 3000:80

$b64 = kubectl --namespace monitoring get secret monitoring-grafana -o jsonpath="{.data.admin-password}"
[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
```


> Open Grafana at [http://localhost:3000](http://localhost:3000) (login `admin` / `admin`).
> Kind maps host ports via `extraPortMappings` — no `kubectl port-forward` needed.



## 3. CNPG operator

> Installs the CloudNativePG operator (chart v0.29.2 → operator v1.30.2) into the
> `cnpg-system` namespace via Helm.

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace \
  --version 0.29.2 \
  -f manifests/cnpg-operator-values.yaml

kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg

# Official CNPG Grafana dashboard (ConfigMap in monitoring; Grafana sidecar auto-loads it)
kubectl -n monitoring get configmap cnpg-grafana-dashboard
```
#### Windows
```powershell
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

helm upgrade --install cnpg cnpg/cloudnative-pg `
  --namespace cnpg-system --create-namespace `
  --version 0.29.2 `
  -f manifests/cnpg-operator-values.yaml
  
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg

# Official CNPG Grafana dashboard (ConfigMap in monitoring; Grafana sidecar auto-loads it)
kubectl -n monitoring get configmap cnpg-grafana-dashboard
```

> Grafana login `admin` / `prom-operator`. Open **Dashboards → CloudNativePG** after
> port-forwarding Grafana (step 2). The dashboard ConfigMap is labeled
> `grafana_dashboard=1` so the kube-prometheus-stack sidecar imports it.



## 4. CNPG cluster

> A 3-instance Postgres cluster with sync replication and separate data + WAL
> volumes. Metrics are scraped via `manifests/podmonitor.yaml`.

```bash
kubectl apply -f manifests/pg-cluster.yaml
kubectl apply -f manifests/podmonitor.yaml

kubectl wait --for=condition=Ready cluster/pg-cluster --timeout=600s
```



## 5. CNPG plugin

> Adds the `kubectl cnpg` subcommand to inspect and manage the cluster.

```bash
kubectl krew install cnpg
kubectl cnpg status pg-cluster
```



## 6. Chaos Mesh

> `runtime=containerd` and the containerd socket path are required because kind
> nodes use containerd (not Docker).

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update

kubectl create namespace chaos-mesh

helm install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh \
  --version 2.8.8 \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set dashboard.create=true
  --set dashboard.securityMode=false

kubectl --namespace chaos-mesh port-forward svc/chaos-dashboard 2333:2333
```
#### Windows
```powershell
helm install chaos-mesh chaos-mesh/chaos-mesh `
  --namespace chaos-mesh `
  --create-namespace `
  --version 2.8.8 `
  --set chaosDaemon.runtime=containerd `
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock `
  --set dashboard.create=true `
  --set dashboard.securityMode=false

kubectl --namespace chaos-mesh port-forward svc/chaos-dashboard 2333:2333

If chaos-controller-manager pods fail to come up, check the error logs to find the root cause. Then try the fix below:

wsl -d rancher-desktop sysctl -w fs.inotify.max_user_instances=1024
wsl -d rancher-desktop sysctl -w fs.inotify.max_user_watches=524288
```
> Open Chaos Mesh at [http://localhost:2333](http://localhost:2333).

