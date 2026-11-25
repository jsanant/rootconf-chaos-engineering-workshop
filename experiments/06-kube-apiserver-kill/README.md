# 6. kube-apiserver Kill

## What this experiment does

You kill the **Kubernetes API server** static pod on the kind control-plane and compare:

- **Data plane** — already-running CNPG Postgres pods and the loadgen SQL traffic
- **Control plane** — anything that needs the API (`kubectl`, CNPG operator, many controllers)

Together with [05-etcd-kill](../05-etcd-kill/):

| Experiment | What dies | Rough analogy |
|------------|-----------|----------------|
| 05 etcd | Cluster state store | Database for Kubernetes itself |
| 06 apiserver | Front door to that store | API in front of that database |

Postgres table data still lives on instance disks either way.

## Mental model

```
loadgen ──► Service pg-cluster-rw ──► primary Postgres pod     ← keep serving if already up
CNPG operator ──► kube-apiserver ──► etcd                    ← blocked
you + kubectl ──► kube-apiserver                             ← blocked
```

The apiserver is **not** on the SQL path. While it is down, check whether loadgen still prints healthy writes even though `kubectl get` fails.

## What Chaos Mesh targets

`PodChaos` `pod-kill` on:

```yaml
namespaces: [kube-system]
labelSelectors:
  component: kube-apiserver
  tier: control-plane
```

On kind: `kube-apiserver-<cluster>-control-plane`, recreated by kubelet. You need a **chaos-daemon on the control-plane** (same as experiment 05).

## What you should see

| Layer | Likely behaviour |
|-------|------------------|
| apiserver pod | Killed; kubelet recreates (listing can lag) |
| `kubectl` | Connection refused, TLS timeouts, or errors |
| CNPG operator | No successful reconcile / failover |
| loadgen | Often continues `WRITE ok` / `READ ok` |
| After recover | `/healthz` ok; `kubectl cnpg status` works; cluster Ready |

This experiment does **not** delete CNPG pods. Blocked healing after instance loss is [07](../07-instance-loss-while-operator-blind/).

## Before you start

```bash
kubectl -n kube-system get pods -l component=kube-apiserver -o wide
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
kubectl -n chaos-mesh get pods -l app.kubernetes.io/component=chaos-daemon -o wide
kubectl get pods -l app=cnpg-loadgen
```

Start or keep loadgen (`make loadgen`) and leave logs open:

```bash
kubectl -n default logs -l app=cnpg-loadgen -f --tail=20
```

Note a few consecutive `WRITE ok` / `READ ok` lines so you can compare during the outage.

## Run the experiment

### 1. Capture baseline

```bash
kubectl -n kube-system get pod -l component=kube-apiserver
kubectl get --raw=/healthz || true
kubectl cnpg status pg-cluster
kubectl -n default logs -l app=cnpg-loadgen --tail=20
```

### 2. Start the chaos

```bash
kubectl apply -f chaos.yaml
kubectl describe podchaos kube-apiserver-kill
```

Confirm `AllInjected=True` and a successful apply on the apiserver pod.

### 3. Observe control plane vs data plane

```bash
kubectl -n kube-system get pods -l component=kube-apiserver -o wide
kubectl get --raw=/healthz || echo "api down"
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide || true
kubectl -n default logs -l app=cnpg-loadgen --tail=30
```

Expect `kubectl` to fail or flap while loadgen may still succeed. “Kubernetes is down” here means the **API** is down—the database process can still be fine.

### 4. Clean up and confirm recovery

```bash
kubectl delete -f chaos.yaml --ignore-not-found
kubectl -n kube-system wait --for=condition=Ready pod -l component=kube-apiserver --timeout=180s
kubectl wait --for=condition=Ready cluster/pg-cluster --timeout=300s
kubectl get --raw=/healthz
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
kubectl -n default logs -l app=cnpg-loadgen --tail=10
```

Confirm a stable API and **3** ready instances before experiment 07.

## Notes

- Use only on local kind—not on shared/production control planes.
- Run after earlier experiments when you can; API flaps disturb open watches.
- Next: [07-instance-loss-while-operator-blind](../07-instance-loss-while-operator-blind/).
