# 4. Operator Partition from the Cluster

## What this experiment does

You network-partition the **CloudNativePG operator** (`cnpg-system`) from the **Postgres pods** (`pg-cluster`). The database can keep serving queries; the operator cannot reach the instances to reconcile failover, recreation, or similar lifecycle work.

## What you should see

- Primary/replicas still answer SQL (steady-state queries do not need the operator)
- Operator logs show connection / reconcile problems toward the instances
- After the partition ends, the operator catches up and the cluster stays or returns healthy

## Before you start

```bash
kubectl -n cnpg-system get pods
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
```

Optional:

```bash
kubectl -n default logs -l app=cnpg-loadgen -f --tail=20
```

## Run the experiment

### 1. Start the partition

```bash
kubectl apply -f chaos.yaml
kubectl describe networkchaos operator-partition
```

Operator pods are partitioned from all `cnpg.io/cluster=pg-cluster` pods for **2 minutes**.

### 2. Observe data plane vs control path

```bash
# Database should still answer
kubectl cnpg psql pg-cluster -- -c "SELECT inet_server_addr(), pg_is_in_recovery();"

kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
kubectl -n cnpg-system logs deploy/cnpg-cloudnative-pg --tail=50
kubectl -n default logs -l app=cnpg-loadgen --tail=20
kubectl describe networkchaos operator-partition
```

Expect: SQL and loadgen still succeed; operator logs look unhealthy toward the instances.

Optional follow-on (skip the first time): delete a replica **during** the partition and watch recreation stall until the Chaos CR is gone (experiment [07](../07-instance-loss-while-operator-blind/) covers this end-to-end).

```bash
REPLICA=$(kubectl get pods -l cnpg.io/cluster=pg-cluster,role=replica -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod "$REPLICA"
kubectl get pods -l cnpg.io/cluster=pg-cluster -w
```

### 3. End the chaos and verify

```bash
kubectl delete -f chaos.yaml --ignore-not-found
kubectl wait --for=condition=Ready cluster/pg-cluster --timeout=300s
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
```

Confirm **3** ready instances before moving on.
