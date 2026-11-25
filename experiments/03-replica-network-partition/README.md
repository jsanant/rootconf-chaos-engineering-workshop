# 3. Replica Pod Network Partition

## What this experiment does

You partition **one replica** from the rest of the Postgres cluster (primary + other replica). Unlike primary partition, the primary should stay writable; only that replica loses connectivity / falls behind.

## What you should see

- Primary keeps `role=primary` and accepts writes
- The isolated replica shows disconnect, lag, or NotReady
- No automatic failover (only a standby is cut off)
- After heal, the replica catches up or is rebuilt; cluster returns to 3 healthy instances

## Before you start

```bash
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster,role=replica -o wide
PRIMARY=$(kubectl get pods -l cnpg.io/cluster=pg-cluster,role=primary -o jsonpath='{.items[0].metadata.name}')
echo "Primary (should stay primary): $PRIMARY"
```

Optional loadgen watch:

```bash
kubectl -n default logs -l app=cnpg-loadgen -f --tail=20
```

## Run the experiment

### 1. Start the partition

```bash
kubectl apply -f chaos.yaml
kubectl describe networkchaos replica-network-partition
```

`mode: one` picks a single replica and partitions it from every other `pg-cluster` pod for **90 seconds**.

### 2. Observe cluster and service

```bash
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
kubectl describe networkchaos replica-network-partition
kubectl -n default logs -l app=cnpg-loadgen --tail=20
```

Confirm:

- Primary name is unchanged
- One replica is unhealthy or lagging
- Loadgen still reports `WRITE ok` / `READ ok` (primary path)

Optional SQL check against the primary:

```bash
kubectl cnpg psql pg-cluster -- -c "SELECT now(), pg_is_in_recovery();"
```

(`pg_is_in_recovery()` should be `f` on the primary.)

### 3. End the chaos and verify

```bash
kubectl delete -f chaos.yaml --ignore-not-found
kubectl wait --for=condition=Ready cluster/pg-cluster --timeout=300s
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
```

You should again have **3** ready instances before continuing.
