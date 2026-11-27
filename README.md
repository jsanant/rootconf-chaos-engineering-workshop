# CNPG Chaos Engineering Workshop

Hands-on workshop: run [CloudNativePG](https://cloudnative-pg.io/) on [kind](https://kind.sigs.k8s.io/), inject failures with [Chaos Mesh](https://chaos-mesh.org/), and watch recovery under load (Grafana + a small SQL loadgen).

## Repo layout

| Path | What it is |
|------|------------|
| `Makefile` | Main entry: `check`, `cache`, `load`, `install`, `ui`, `teardown` |
| `Setup.md` | Manual / copy-paste install steps |
| `kind-config.yaml` | kind cluster (1 control-plane + 3 workers, UI host ports) |
| `manifests/` | CNPG `Cluster`, PodMonitor, operator Helm values |
| `experiments/` | Chaos experiments (README + YAML per scenario) |
| `loadgen/` | Go R/W client against `pg-cluster-rw` |
| `artifacts/` | Offline image/chart cache (`images.txt`, tarballs after `make cache`) |
| `scripts/` | Tool install, image cache/load helpers |

## Quick start

```bash
# 1) (Recommended) Prefetch images + charts while network is good
make cache

# 2) Install the stack (use OFFLINE=1 to consume the cache)
make install
# or: make install OFFLINE=1

# 3) Optional: SQL load traffic
make loadgen

# 4) Open UIs (no port-forward; kind publishes host ports)
make ui
```

| UI | URL | Login |
|----|-----|--------|
| Grafana | http://localhost:3000 | `admin` / `admin` |
| Chaos Mesh | http://localhost:2333 | — |

Tear down: `make teardown`.

## Prefetch images (offline / flaky network)

Do this **before** the workshop or whenever registry TLS is painful (corp proxy, MITM, slow links).

```bash
# Pull every image in artifacts/images.txt and Helm charts into artifacts/
make cache

# After kind exists: docker load + kind load into the cluster nodes
make load

# Install without hitting helm repos / registries for charts
make install OFFLINE=1
```

Details: [artifacts/README.md](artifacts/README.md). Image list: [artifacts/images.txt](artifacts/images.txt).

## What `make install` brings up

1. CLI tools into `./bin` if missing (`kind`, `kubectl`, `helm`, `jq`, krew + `kubectl-cnpg`)
2. kind cluster `cnpg-chaos`
3. kube-prometheus-stack (Prometheus + Grafana)
4. CloudNativePG operator + 3-instance sync Postgres (`pg-cluster`) with separate data/WAL volumes
5. Chaos Mesh (daemon on every node, including control-plane)

Then `make loadgen` for SQL traffic, and run experiments under [experiments/](experiments/README.md).

## Useful commands

```bash
make check          # docker + CLIs
make loadgen        # rebuild/redeploy loadgen only
kubectl cnpg status pg-cluster
kubectl -n default logs -l app=cnpg-loadgen -f
```
