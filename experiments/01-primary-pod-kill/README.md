# 1. Primary Pod Kill

## What this experiment does

You force-kill the Postgres **primary** pod and watch CloudNativePG recover:

1. Detect that the primary is gone
2. Promote a healthy replica (failover)
3. Bring the cluster back to 3 instances

## What you should see

- Short write disruption for clients on the old primary
- A **new** primary in `kubectl cnpg status` (different pod name)
- All three pods `Ready` again after the operator finishes reconciling

## Before you start

Cluster and Chaos Mesh should already be up (`make all` or [Setup.md](../../Setup.md)).

```bash
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
```

Write down the current primary (`role=primary`). Optionally keep loadgen logs open in another terminal:

```bash
kubectl -n default logs -l app=cnpg-loadgen -f --tail=20
```

## Run the experiment

### 1. Watch the pods (optional second terminal)

```bash
kubectl get pods -l cnpg.io/cluster=pg-cluster -w
```

### 2. Start the chaos

From this directory:

```bash
kubectl apply -f chaos.yaml
```

Chaos Mesh kills one pod with `cnpg.io/cluster=pg-cluster` and `role=primary`.

Confirm injection:

```bash
kubectl describe podchaos primary-pod-kill
# Look for AllInjected=True and Successfully apply … pg-cluster-…
```

### 3. Observe cluster and loadgen

```bash
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
kubectl get events --field-selector involvedObject.name=pg-cluster --sort-by='.lastTimestamp' | tail -20
kubectl -n default logs -l app=cnpg-loadgen --tail=30
```

Check for:

- Old primary terminating
- A former replica labeled `role=primary`
- A new pod starting so you again have 3 instances
- Loadgen: brief errors, then `WRITE ok` / `READ ok` again

### 4. Clean up and confirm recovery

```bash
kubectl delete -f chaos.yaml --ignore-not-found
kubectl wait --for=condition=Ready cluster/pg-cluster --timeout=300s
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
```

Do not start the next experiment until status shows a healthy cluster with **3** ready instances.
