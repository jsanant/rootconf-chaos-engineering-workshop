# 7. Instance Loss While the Operator Is Blind

## What this experiment does

You remove a **CNPG replica** while the **operator cannot reach the cluster**, so automatic recreate/heal cannot finish until connectivity returns.

Experiments [05](../05-etcd-kill/) and [06](../06-kube-apiserver-kill/) show SQL can continue while etcd/API are briefly down. This one answers: if an instance also disappears while the control path is blind, does HA still heal?

### Why the YAML partitions the operator (not the apiserver)

On kind, kube-apiserver and etcd are **static pods**. A Chaos Mesh `pod-kill` is often healed by kubelet in seconds, and CNPG can recreate a replica in that gap—so a long “stuck missing pod” window is hard to hold with apiserver/etcd PodChaos alone.

This experiment instead:

1. **Partitions** the CNPG operator from all `pg-cluster` pods (same idea as [04](../04-operator-partition/))
2. **Kills** one replica

| Ideal (API/etcd dark for a long time) | What you run here (operator partitioned) |
|---------------------------------------|------------------------------------------|
| Operator cannot use API / state | Operator cannot reach instances |
| Missing pod is not recreated | Missing replica is not recreated |
| Surviving primary may still serve SQL | Surviving primary may still serve SQL |
| `kubectl` often broken | `kubectl` still works (easier to observe) |

Same outcome for HA: **instance gone + blind control path ⇒ no automatic heal until control returns.**

## What you should see

| Phase | What to look for |
|-------|------------------|
| After apply | NetworkChaos + PodChaos injected; replica killed |
| During (~90s) | Often only **2** Running `pg-cluster-*` pods |
| During | No lasting third instance until the partition ends |
| During | Primary + loadgen usually still `WRITE ok` / `READ ok` |
| After cleanup | Operator reconnects; third instance returns; Ready **3/3** |

## Before you start

```bash
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
kubectl -n cnpg-system get pods
kubectl get pods -l app=cnpg-loadgen
```

```bash
PRIMARY=$(kubectl get pods -l cnpg.io/cluster=pg-cluster,role=primary -o jsonpath='{.items[0].metadata.name}')
echo "Primary (should survive): $PRIMARY"
kubectl get pods -l cnpg.io/cluster=pg-cluster,role=replica -o wide
```

Optional log watch:

```bash
kubectl -n default logs -l app=cnpg-loadgen -f --tail=20
```

## Run the experiment

### 1. Start both chaos objects

```bash
kubectl apply -f chaos.yaml
kubectl get networkchaos,podchaos -l experiment=instance-loss-while-operator-blind
kubectl describe networkchaos operator-blind-during-instance-loss
kubectl describe podchaos replica-kill-while-operator-blind
```

Confirm the replica PodChaos applied successfully and the network partition is active.

### 2. Observe pods and loadgen

In one terminal (or re-run every few seconds):

```bash
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
kubectl cnpg status pg-cluster
kubectl -n default logs -l app=cnpg-loadgen --tail=30
```

Or continuous pod watch:

```bash
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide -w
```

Expect about **2** Running instances for most of the ~90s window, with loadgen still succeeding against the primary.

### 3. End the chaos and verify recovery

```bash
kubectl delete -f chaos.yaml --ignore-not-found
kubectl wait --for=condition=Ready cluster/pg-cluster --timeout=300s
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
kubectl -n default logs -l app=cnpg-loadgen --tail=10
```

You should see a new/replaced third instance and status **Ready** with 3 instances.

## Optional variants

- Change the PodChaos selector to `role: primary` for a harder case (writes fail until failover can run—also needs the operator path). Try the replica case first.
- On platforms where you can hold the apiserver down for tens of seconds, you can pair experiment 06 with a replica kill; on kind, prefer this operator-blind form.

## Notes

- Use on local kind only.
- Finish 04–06 first when you can, so the operator-partition and API/etcd ideas are familiar.
- Always return to **3** ready instances before leaving this experiment.
