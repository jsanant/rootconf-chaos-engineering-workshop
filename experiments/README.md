# CNPG Chaos Experiments

Chaos Mesh experiments against a 3-instance CloudNativePG cluster (`pg-cluster`: 1 primary + 2 replicas) on kind.

## Before you start

Finish setup ([Setup.md](../Setup.md) or `make install` from the repo root) so you have:

- kind cluster `cnpg-chaos` (1 control-plane + 3 workers)
- kube-prometheus-stack in `monitoring` (unless you skipped it)
- CNPG operator in `cnpg-system` and a Ready `Cluster/pg-cluster`
- Chaos Mesh 2.8.8 in `chaos-mesh`
- `kubectl cnpg` plugin
- Loadgen deployed (`make loadgen`) — useful for every experiment

Check the cluster and loadgen:

```bash
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
kubectl get pods -l app=cnpg-loadgen
kubectl -n default logs -l app=cnpg-loadgen --tail=10
```

## Experiments

| # | Experiment | Chaos Mesh kind | Directory |
|---|------------|-----------------|-----------|
| 1 | Primary Pod Kill | `PodChaos` (`pod-kill`) | [01-primary-pod-kill](01-primary-pod-kill/) |
| 2 | Primary network partition | `NetworkChaos` (`partition`) | [02-primary-network-partition](02-primary-network-partition/) |
| 3 | Replica network partition | `NetworkChaos` (`partition`) | [03-replica-network-partition](03-replica-network-partition/) |
| 4 | Operator partition from cluster | `NetworkChaos` (`partition`) | [04-operator-partition](04-operator-partition/) |
| 5 | etcd kill | `PodChaos` (`pod-kill`) | [05-etcd-kill](05-etcd-kill/) |
| 6 | kube-apiserver kill | `PodChaos` (`pod-kill`) | [06-kube-apiserver-kill](06-kube-apiserver-kill/) |
| 7 | Instance loss while operator blind | `NetworkChaos` + `PodChaos` | [07-instance-loss-while-operator-blind](07-instance-loss-while-operator-blind/) |

Each folder has a `README.md` (what to expect + steps) and a `chaos.yaml` you apply with `kubectl apply -f chaos.yaml` from that folder.

**05–06:** data plane can keep serving while etcd/API are briefly down.  
**07:** a replica is killed while the operator cannot reach the cluster, so the missing instance is not recreated until the control path returns.

## How to run any experiment

1. `cd` into the experiment directory  
2. Confirm the cluster is healthy (`kubectl cnpg status pg-cluster` → 3 ready)  
3. Optionally open loadgen logs: `kubectl -n default logs -l app=cnpg-loadgen -f`  
4. `kubectl apply -f chaos.yaml`  
5. Follow the **Observe** steps in that experiment’s README  
6. `kubectl delete -f chaos.yaml --ignore-not-found` (or wait for `duration`)  
7. Wait until the cluster is Ready with 3 instances before the next experiment  

## Useful commands while you observe

```bash
# Topology and replication
kubectl cnpg status pg-cluster

# Instance pods
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide

# Continuous pod watch
kubectl get pods -l cnpg.io/cluster=pg-cluster -w

# Loadgen (R/W against pg-cluster-rw)
kubectl -n default logs -l app=cnpg-loadgen --tail=50
kubectl -n default logs -l app=cnpg-loadgen -f

# Chaos object status
kubectl get podchaos,networkchaos
kubectl describe podchaos <name>
kubectl describe networkchaos <name>

# UIs (published by kind — no port-forward)
# Grafana: http://localhost:3000  (admin / admin)
# Chaos Mesh: http://localhost:2333
make ui
```

## Ideas for later (not packaged here)

1. Replica pod kill without failover  
2. Primary CPU / memory stress (`StressChaos`)  
3. Replica lag via network **delay** (not full partition)  
4. DNSChaos against `pg-cluster-rw` / `pg-cluster-ro`  
5. Time skew on the primary (`TimeChaos`)  
6. Kill all replicas at once  
7. Chaos during a planned switchover  
8. `pod-failure` on the primary vs `pod-kill`  
9. HTTPChaos on metrics / probes  
10. Multi-step Chaos Mesh `Workflow`  
