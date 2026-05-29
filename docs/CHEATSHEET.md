# GPU Trainer — Cheat Sheet

Brief, reviewable log of what we built and *why*. Mirrors Baseten's shape:
IaC provisions the cluster → Flux (GitOps) delivers infra controllers → then apps.
A global scheduler (Baseten's "MCM") sits above per-cluster Flux. We're learning the per-cluster layer.

## Mental model (the one big idea)

- **Thin per-cloud bottom layer** (provisioning: EKS+Karpenter / bare-metal kubeadm) — tailored, unavoidable.
- **Thick portable top layer** (GPU Operator, monitoring, runtimes, apps) — *identical everywhere*, delivered by Flux from one fleet repo.
- This portability is what lets a global scheduler treat all clusters as one fungible GPU pool.

## Repos

| Repo | Location | Role | Pushed? |
|------|----------|------|---------|
| `flux-gpu-trainer` | local only | workbench: hard-way PKI/scripts, Pulumi IaC, notes | never |
| `fleet-infra` | github.com/slikk66 (private) | GitOps source of truth + Pulumi IaC | yes |

`fleet-infra` layout (Flux monorepo): `clusters/<name>/` (entrypoints) · `infrastructure/controllers/{base,<cluster>}` · `apps/{base,<cluster>}` · `iac/` (Pulumi).
Reconcile order per cluster: **infrastructure before apps**.

## Clusters

- **hardway** — "Kubernetes the hard way" on OrbStack Ubuntu arm64 VMs (control-1 + worker-1/2). Cilium CNI w/ kube-proxy replacement. ≈ the "bare-metal / colo" experience.
- **aws-gpu** (planned) — g5.xlarge (A10G) **spot**, us-west-2, k3s, real NVIDIA GPU Operator. ≈ the "managed cloud" experience. Both reconcile the *same* infra/apps from `fleet-infra`.

---

## Steps performed (chronological)

### 1. Tooling
- `brew install fluxcd/tap/flux` → flux v2.8.8. kubectl v1.35.3, kustomize v5.8.1.
- Auth: used `gh` token for one-time bootstrap (`export GITHUB_TOKEN=$(gh auth token)`).
  - *Why fine for learning:* bootstrap uses the token **once** to commit manifests + create a **read-only deploy key**. The durable in-cluster credential is the deploy key, not the token.
  - *Baseten-shaped:* prod drives bootstrap from IaC using a GitHub App / machine-user PAT. Same end-state deploy key. We'll use a fine-grained PAT for Track B.

### 2. Bootstrap Flux onto `hardway`
```bash
export GITHUB_TOKEN=$(gh auth token)
export KUBECONFIG=.../k8s-hardway/admin.kubeconfig
flux bootstrap github --owner=slikk66 --repository=fleet-infra \
  --branch=main --path=clusters/hardway --private --personal
```
Installs controllers in `flux-system`, commits `clusters/hardway/flux-system/*`, registers deploy key,
creates self-sync GitRepository + Kustomization.

### 3. Hard-way gaps found & fixed (NOT normal for managed k8s)

**(a) apiserver → kubelet RBAC missing** — `kubectl logs/exec/port-forward` returned `Forbidden ... nodes/proxy`.
The apiserver authenticates to kubelets as user `kubernetes` but had no RBAC. Fix:
```bash
# ClusterRole system:kube-apiserver-to-kubelet (nodes/proxy,stats,log,spec,metrics)
# + ClusterRoleBinding system:kube-apiserver -> User "kubernetes"
```

**(b) apiserver `--advertise-address=127.0.0.1`** — root cause of Flux CrashLoopBackOff.
- Symptom: pods dialing the `kubernetes` ClusterIP `10.32.0.1:443` got `connect: operation not permitted`.
- Cause: with 127.0.0.1 advertised, the `kubernetes` service had **no EndpointSlice** → no backend.
  Cilium agents were fine because they run host-network and connect via `KUBERNETES_SERVICE_HOST=k8s-control`.
- Fix on control-1: edit `/etc/systemd/system/kube-apiserver.service` →
  `--advertise-address=192.168.139.92`; `daemon-reload`; `restart kube-apiserver`. (backup: `*.service.bak`)
- Result: EndpointSlice `kubernetes → 192.168.139.92:6443` published; restarted Flux pods → all 1/1 Running.

### 4. DNS bootstrap chicken-and-egg (current)
- Flux reaches the API now, but source-controller can't resolve `github.com`:
  `lookup github.com on 10.32.0.10:53: i/o timeout` — **no CoreDNS in the cluster**.
- CoreDNS was intended via GitOps, but Flux needs DNS to clone the repo that *contains* CoreDNS.
- **Resolution:** seed CoreDNS once (manual apply), then commit CoreDNS to `fleet-infra/infrastructure`
  so Flux adopts & manages it going forward. (Standard: every cluster has a minimal bootstrap seed.)

---

## Quick reference

```bash
export KUBECONFIG=.../k8s-hardway/admin.kubeconfig

flux get sources git            # is the repo synced?
flux get kustomizations         # are paths applied?
flux reconcile source git flux-system   # force pull
kubectl -n flux-system get pods
kubectl -n flux-system logs deploy/source-controller --tail=20
```

## Node / cluster facts
- control-1 `192.168.139.92` (apiserver, not a registered node), worker-1 `192.168.139.161`, worker-2 `192.168.139.68`.
- Service CIDR `10.32.0.0/24` (apiserver `10.32.0.1`, DNS `10.32.0.10`). Pod CIDR `10.200.0.0/16`.
- IPs via `k8s-hardway/sync-hosts.sh` (updates nodes' /etc/hosts from live OrbStack IPs).
</content>
