# 2. Primary Pod Network Partition

## What this experiment does

You isolate the **primary** from the **replicas** on the network (the primary process keeps running). Streaming replication and peer reachability break while the pod is still “alive,” which can trigger fencing / failover.

## What you should see

- Replication to replicas stalls (lag or dropped connections)
- CNPG may mark the primary unhealthy and **failover** to a replica
- After the partition ends (or you delete the Chaos CR), the cluster returns to a healthy 3-instance topology

## Before you start

```bash
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide --show-labels
```

```bash
PRIMARY=$(kubectl get pods -l cnpg.io/cluster=pg-cluster,role=primary -o jsonpath='{.items[0].metadata.name}')
echo "Primary before chaos: $PRIMARY"
```

Optional: Grafana / Chaos Mesh UI and loadgen logs in other terminals.

```bash
kubectl -n default logs -l app=cnpg-loadgen -f --tail=20
```

## Run the experiment

### 1. Start the partition

```bash
kubectl apply -f chaos.yaml
kubectl describe networkchaos primary-network-partition
```

This partitions the primary from all `role=replica` pods for **90 seconds** (both directions).

### 2. Observe while it is active

```bash
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
kubectl describe networkchaos primary-network-partition
kubectl -n default logs -l app=cnpg-loadgen --tail=30
```

Look for:

- Role label changes (`role=primary` moves)
- Unready pods or lag in status / Grafana
- Loadgen errors or recovery around failover

### 3. End the chaos and verify

Wait for the 90s duration, or force heal:

```bash
kubectl delete -f chaos.yaml --ignore-not-found
kubectl wait --for=condition=Ready cluster/pg-cluster --timeout=300s
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
```

Confirm **3** ready instances and a clear primary before the next experiment.
