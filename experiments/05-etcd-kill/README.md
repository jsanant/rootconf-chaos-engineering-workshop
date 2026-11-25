# 5. etcd Kill

## What this experiment does

You kill the **Kubernetes etcd** static pod on the kind control-plane and compare that to killing a Postgres pod (experiments 01–04).

etcd stores **Kubernetes cluster state** (Pod specs, Secrets, CNPG `Cluster` status, leases, …). It does **not** store Postgres table data or WAL—those live on the instance PVCs.

Question to answer while it runs: if Kubernetes’ source of truth disappears briefly, does Postgres keep serving, and what stops working?

## Mental model

```
Clients / loadgen ──SQL──► Postgres pods (data plane)     ← often keeps working
                              ▲
                              │ reconcile / failover / create Pod
CNPG operator ──watch/API──► kube-apiserver ──► etcd     ← this path breaks
kubectl ─────────────────────► kube-apiserver ──► etcd
```

When etcd dies:

- The apiserver may time out, error, or lose leases/watches
- The CNPG operator cannot reliably update cluster state or create replacement pods
- Running Postgres processes do not need etcd per query; they keep using local data until something needs the control plane (failover, new pod, etc.)

## What Chaos Mesh targets

`PodChaos` `pod-kill` on:

```yaml
namespaces: [kube-system]
labelSelectors:
  component: etcd
  tier: control-plane
```

On kind that is `etcd-<cluster>-control-plane`. kubelet recreates it from `/etc/kubernetes/manifests/etcd.yaml`.

A Chaos Mesh `chaos-daemon` must run **on the control-plane node**. Without it, the experiment selects but never injects.

## What you should see

| Layer | Likely behaviour |
|-------|------------------|
| etcd pod | Terminated; kubelet starts a new one |
| kube-apiserver | Timeouts / `/healthz` flaps |
| `kubectl` / `kubectl cnpg` | Fail or hang until etcd+API recover |
| CNPG operator | Cannot reconcile / drive failover |
| Postgres + loadgen | Often continues R/W on already-running pods |
| After recover | API healthy; `cluster/pg-cluster` Ready |

This experiment does **not** delete CNPG pods. For instance loss while healing is blocked, use [07](../07-instance-loss-while-operator-blind/).

## Before you start

```bash
kubectl -n kube-system get pods -l component=etcd -o wide
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
kubectl -n chaos-mesh get pods -l app.kubernetes.io/component=chaos-daemon -o wide
```

Confirm a chaos-daemon is listed on the control-plane. If not:

```bash
kubectl -n chaos-mesh patch ds chaos-daemon --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/tolerations","value":[
    {"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},
    {"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}
  ]}
]'
```

Keep loadgen running if you have it (`make loadgen`):

```bash
kubectl -n default logs -l app=cnpg-loadgen -f --tail=20
```

## Run the experiment

### 1. Capture baseline

```bash
kubectl -n kube-system get pod -l component=etcd
kubectl get --raw=/healthz || true
kubectl cnpg status pg-cluster
kubectl -n default logs -l app=cnpg-loadgen --tail=15
```

### 2. Start the chaos

```bash
kubectl apply -f chaos.yaml
kubectl describe podchaos etcd-kill
```

Confirm `AllInjected=True` and a successful apply on the etcd pod.

### 3. Observe control plane vs data plane

Use a watch or repeated commands (many `kubectl` calls will fail mid-outage—retry):

```bash
kubectl -n kube-system get pods -l component=etcd -o wide
kubectl get --raw=/healthz || echo "api degraded"
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide || true
kubectl -n default logs -l app=cnpg-loadgen --tail=30
```

Compare: loadgen may still show `WRITE ok` / `READ ok` while `kubectl` fails. That is the split between data plane and control plane.

### 4. Clean up and confirm recovery

```bash
kubectl delete -f chaos.yaml --ignore-not-found
kubectl -n kube-system wait --for=condition=Ready pod -l component=etcd --timeout=180s
kubectl wait --for=condition=Ready cluster/pg-cluster --timeout=300s
kubectl get --raw=/healthz
kubectl cnpg status pg-cluster
kubectl get pods -l cnpg.io/cluster=pg-cluster -o wide
```

Wait until the API is stable and the cluster shows **3** ready instances before experiment 06.

## Notes

- Safe on local kind; do not run against shared/production control planes.
- API flaps can disturb watches and dashboards; finish earlier experiments first when you can.
- Next: [06-kube-apiserver-kill](../06-kube-apiserver-kill/) (API front door vs etcd store).
