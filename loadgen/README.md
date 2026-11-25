# CNPG loadgen

Small Go client that inserts a heartbeat row and reads `COUNT(*)` every `INTERVAL_MS` (default **2000**) against `pg-cluster-rw`.

Use it during chaos experiments to see whether **SQL traffic** keeps working when Kubernetes or the operator is unhealthy.

## Deploy

From the repo root (cluster and `pg-cluster` must already exist):

```bash
make loadgen
```

Follow live output:

```bash
make loadgen-logs
# or:
kubectl -n default logs -l app=cnpg-loadgen -f --tail=50
```

Healthy lines look like:

```text
WRITE ok (ok=N err=0)
READ  ok count=N (ok=N err=0)
```

During an outage you may see `WRITE fail` / `READ fail`; after recovery, `ok` counts should rise again.

Check the pod:

```bash
kubectl get pods -l app=cnpg-loadgen -o wide
kubectl get deploy cnpg-loadgen
```

## Build details

Default `make loadgen-build` compiles with **local Go** and packs a `scratch` image (works when Docker cannot pull build base images).

Optional full Docker build (needs working registry TLS):

```bash
make loadgen LOADGEN_DOCKER_BUILD=1
```

## Config (env)

| Variable | Default | In-cluster source |
|----------|---------|-------------------|
| `PGHOST` | `pg-cluster-rw` | deployment |
| `PGUSER` / `PGPASSWORD` | — | secret `pg-cluster-app` |
| `PGDATABASE` | `app` | deployment |
| `PGSSLMODE` | `require` | deployment |
| `INTERVAL_MS` | `2000` | `LOADGEN_INTERVAL_MS` when you run `make` |
| `DATABASE_URL` | — | optional full URL override |
