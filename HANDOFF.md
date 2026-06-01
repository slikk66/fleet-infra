# HANDOFF — flux-gpu-trainer / fleet-infra

> Read this top-to-bottom before doing anything. It lets a cold agent resume exactly where we are.
> Companion doc: `docs/CHEATSHEET.md` (teaching log + Flux/Kustomize reference). Keep both updated.

---

## 0. TL;DR — current state (2026-06-01)

- **Goal:** the user got a job at **Baseten** (AI inference, NVIDIA GPUs across 15+ clouds + bare-metal colos). This is a **hands-on learning exercise** to get fluent in **Flux (GitOps)**, **GPU scheduling / NVIDIA GPU Operator**, and **cloud-agnostic provisioning**. The user knows k8s + Argo CD + AWS well; Flux and GPU scheduling are the gaps.
- **This is a TEACHING engagement.** The user is going concept-by-concept and wants explanations *as we build*, not just execution. Match that: explain the "why," correct misconceptions directly, keep answers concise.
- **Where we are:** Flux is fully healthy on hardway. **fake-gpu-operator (v0.0.81) is installed via OCI HelmRelease** and advertising `nvidia.com/gpu: 2` per worker (2x NVIDIA-H100-80GB-HBM3 simulated, 4 total in cluster). **`apps/` layer** is wired with `dependsOn: [infrastructure]` + `wait: true`; a `gpu-demo` Deployment scales to 4 replicas, scheduler bin-packs 2 per worker, device-plugin injects `MOCK_NVIDIA_VISIBLE_DEVICES` per pod. End-to-end GPU scheduling chain proven on fake hardware.
- **Next planned step:** Track B — Pulumi-provisioned AWS g5.xlarge spot + k3s + real NVIDIA GPU Operator + real CUDA workload. **MIG on the fake operator was deferred** (poorly documented; real MIG learning belongs on real silicon).

---

## 1. Environment / working dirs

- Platform: macOS (Apple M4, 64GB). Shell: zsh. **A git hook (rtk) mangles `git` CLI output in Bash** — read git state from `.git/` files (`.git/HEAD`, `.git/refs/heads/main`) or use `flux`/`kubectl` instead. Plain `git add/commit/push` via the Bash tool have worked despite noisy output.
- **Two repos (deliberate split):**
  - `/Users/dbilleci/Development/slikk66/flux-gpu-trainer` — **LOCAL ONLY, never pushed, no origin.** Workbench. Contains `k8s-hardway/` (the cluster's PKI/scripts) and `.gitignore`. Has NO commits (untracked). Secrets here are gitignored.
  - `/Users/dbilleci/Development/slikk66/fleet-infra` — **private GitHub repo** `git@github.com:slikk66/fleet-infra`, branch `main`. The **GitOps source of truth** + (planned) Pulumi IaC. This is where all GitOps work goes.
- Both are registered as working dirs in this session.

## 2. Tooling (installed + verified)

- `flux` v2.8.8, `kubectl` v1.35.3 (kustomize built-in v5.7.1), `kustomize` v5.8.1, `gh` (authed as **slikk66**, token has `repo` + `admin:public_key`), `brew`.
- **KUBECONFIG for the hardway cluster** (use this for ALL kubectl/flux against it):
  ```bash
  export KUBECONFIG=/Users/dbilleci/Development/slikk66/flux-gpu-trainer/k8s-hardway/admin.kubeconfig
  ```

## 3. The "hardway" cluster (Track A)

- "Kubernetes the hard way" on **OrbStack Ubuntu 24.04 arm64 VMs**. k8s **v1.35.3**. **Cilium CNI** with **kube-proxy replacement** (no kube-proxy, intentional).
- Nodes: `control-1` = **192.168.139.92** (runs apiserver/etcd/controller-mgr/scheduler as raw systemd processes — NOT a registered k8s node), `worker-1` = **192.168.139.161**, `worker-2` = **192.168.139.68** (both `Ready`).
- IPs are managed via `/etc/hosts` on the VMs; refresh with `flux-gpu-trainer/k8s-hardway/sync-hosts.sh` if OrbStack IPs drift (they were stable this session). SSH access: `ssh control-1@orb`, `ssh worker-1@orb`, `ssh worker-2@orb`.
- Service CIDR `10.32.0.0/24` (apiserver `10.32.0.1`, DNS `10.32.0.10`). Pod CIDR `10.200.0.0/16`.

### Cluster fixes applied this session (NOT in git — host/cluster-level hard-way gaps)
1. **apiserver→kubelet RBAC** was missing (`kubectl logs/exec` returned Forbidden). Created ClusterRole `system:kube-apiserver-to-kubelet` + ClusterRoleBinding `system:kube-apiserver` (subject: User `kubernetes`). Applied via kubectl, NOT tracked in git.
2. **apiserver `--advertise-address` was `127.0.0.1`** → the `kubernetes` service had no EndpointSlice → no pod could reach the API (Flux CrashLoopBackOff with `connect: operation not permitted`). Edited `/etc/systemd/system/kube-apiserver.service` on control-1 to `--advertise-address=192.168.139.92`, `daemon-reload`, `restart kube-apiserver`. **Backup at `/etc/systemd/system/kube-apiserver.service.bak` on control-1.**
3. **CoreDNS was absent** (intended to come via GitOps, but Flux needs DNS to clone the repo → chicken-and-egg). **Seeded manually** with `kubectl apply` of `infrastructure/controllers/base/coredns/coredns.yaml`, then committed the same manifest to git so Flux **adopted** it.

> These three are exactly the kind of bare-metal bring-up tasks real provisioning automation (Terraform/Ansible/CAPI) would do *before* Flux runs.

## 4. Flux state (healthy)

- Bootstrapped with: `flux bootstrap github --owner=slikk66 --repository=fleet-infra --branch=main --path=clusters/hardway --private --personal` (token via `export GITHUB_TOKEN=$(gh auth token)`).
- In-cluster: 4 controllers `1/1` in ns `flux-system`. Root `GitRepository` + `Kustomization` (both named `flux-system`) reconciling `path: ./clusters/hardway`. Cluster pulls via a **read-only SSH deploy key** (Secret `flux-system/flux-system`).
- `flux get kustomizations` → `flux-system`, `infrastructure`, **and `apps`** all `READY=True`.
- `flux get helmreleases -A` → `gpu-operator/fake-gpu-operator` `READY=True`, chart `0.0.81+2a66c7929b12`, "Helm install succeeded".
- `flux get sources oci -A` → `flux-system/fake-gpu-operator` `READY=True`, revision `0.0.81@sha256:2a66c792`.

### Verify state quickly
```bash
export KUBECONFIG=/Users/dbilleci/Development/slikk66/flux-gpu-trainer/k8s-hardway/admin.kubeconfig
flux check
flux get sources git
flux get kustomizations
flux get helmreleases -A          # none yet
kubectl get nodes
kubectl -n kube-system get deploy coredns
```

## 5. Repo layout (fleet-infra, current)

```
clusters/hardway/
├── flux-system/                  # bootstrap output (DO NOT EDIT)
├── infrastructure.yaml           # Flux Kustomization → infrastructure/controllers/hardway (prune+wait)
└── apps.yaml                     # Flux Kustomization → apps/hardway (dependsOn infrastructure, wait)

infrastructure/
├── sources/base/                 # OCIRepositories / HelmRepositories — "the catalog"
│   ├── kustomization.yaml
│   └── runai-oci.yaml            # OCIRepository for ghcr.io/run-ai/fake-gpu-operator @ 0.0.81
└── controllers/
    ├── base/
    │   ├── coredns/              # CoreDNS Deployment+Service+CM+RBAC (shared)
    │   └── gpu-operator/         # Namespace + HelmRelease (shared base)
    │       ├── namespace.yaml
    │       ├── helmrelease.yaml  # chartRef → OCIRepository; valuesFrom CM gpu-operator-values
    │       └── kustomization.yaml
    └── hardway/
        ├── kustomization.yaml    # composes ../../sources/base + ../base/coredns + ../base/gpu-operator + local files
        ├── gpu-nodes.yaml        # Node SSA-patches: label workers, prune-disabled (Nodes are co-owned w/ kubelet)
        └── gpu-operator-values.yaml  # ConfigMap: H100 topology (2x NVIDIA-H100-80GB-HBM3, 81559 MiB) — per-cluster

apps/
├── base/gpu-demo/
│   ├── namespace.yaml            # ns: gpu-apps
│   ├── deployment.yaml           # 1 replica, requests nvidia.com/gpu: 1, nodeSelector H100
│   └── kustomization.yaml
└── hardway/
    └── kustomization.yaml        # FIRST REAL OVERLAY: replicas: transformer bumps gpu-demo to 4 replicas

docs/CHEATSHEET.md                # teaching log + Flux/Kustomize/Terraform-mapping reference
HANDOFF.md                        # this file
```

Reconcile chain:
1. Root Flux Kustomization (`gotk-sync.yaml`, `path: ./clusters/hardway`) auto-scans the dir → picks up `infrastructure.yaml` + `apps.yaml`.
2. `infrastructure.yaml` (Flux Kustomization) → `infrastructure/controllers/hardway/kustomization.yaml` (kustomize composition).
3. `apps.yaml` (Flux Kustomization, `dependsOn: [infrastructure]`, `wait: true`) → `apps/hardway/kustomization.yaml`.
4. `infrastructure` reconciles `OCIRepository` (source-controller pulls chart from ghcr.io) + `HelmRelease` (helm-controller installs chart) + Node patches.
5. `apps` waits for `infrastructure` Ready → applies `gpu-demo` Deployment (4 replicas via overlay's `replicas:` transformer).
6. Result: 4 GPU-requesting pods scheduled 2 per worker, fake-gpu-operator's device-plugin allocates a UUID per pod.

## 6. Decisions locked

- **Repos:** local workbench (`flux-gpu-trainer`, never pushed) + GitHub GitOps repo (`fleet-infra`). Two-repo split.
- **Monorepo GitOps layout:** `clusters/<name>/` entrypoints + `infrastructure/` + `apps/`, base+overlay. One dir per cluster; the binding to a cluster is the Flux root Kustomization's `spec.path`, not the dir name.
- **Track B (real GPU):** AWS, **us-west-2** (fallback us-east-2), **g5.xlarge (A10G) spot**, **k3s** single-node (NOT EKS — deliberately bare-metal-shaped), real NVIDIA GPU Operator. Provision with **Pulumi + TypeScript**, **S3 state backend**, `PULUMI_CONFIG_PASSPHRASE=""`. Flux installed on it via the **Pulumi/Terraform Flux provider** (automated bootstrap = the prod-shaped exercise). Reconciles `clusters/aws-gpu/` from the same fleet repo.
- **Auth:** gh token for the manual Track A bootstrap (done); use a **fine-grained PAT** for Track B's IaC-driven bootstrap.

## 7. NEXT STEPS (in order)

1. ~~**Commit pending docs.**~~ ✓ Done.
2. ~~**GPU Operator via HelmRelease.**~~ ✓ Done — fake-gpu-operator v0.0.81 on hardway as OCI HelmRelease; H100 topology in per-cluster CM; 4 fake H100s advertised.
3. ~~**`apps/` layer + ordering.**~~ ✓ Done — `apps.yaml` with `dependsOn: [infrastructure]` + `wait: true`; `gpu-demo` Deployment scheduled with `nvidia.com/gpu: 1` request + H100 nodeSelector; scaled to 4 replicas via overlay's `replicas:` transformer (the first **real** overlay vs the composition we'd been doing); device-plugin injects `MOCK_NVIDIA_VISIBLE_DEVICES` per pod.
4. **Per-cluster customization (partial).** We have the CM-split pattern for values, and one `replicas:` transformer. Still untouched: `postBuild.substituteFrom`, `images:` transformer, `patches:` for env vars / replicas mid-spec. Practice these on Track B where two clusters differ for real reasons.
5. **MIG — DEFERRED to Track B.** fake-gpu-operator's MIG config is undocumented in the chart; not worth reverse-engineering. Real NVIDIA GPU Operator on real A10G/H100 silicon has mature, documented MIG config — learn it there.
6. **Track B (NEXT).** Pulumi TS to provision g5.xlarge spot + k3s + Flux bootstrap via Pulumi/Terraform Flux provider + real NVIDIA GPU Operator + a real CUDA workload (vLLM or simple `nvidia-smi`). Tear down with `pulumi destroy` to control cost. Reconcile from `clusters/aws-gpu/` in this same fleet repo.
7. **Sprinkles when ready:** SOPS for a secret; image-automation for a model-server image; an Alert/Provider for Slack. Save until after Track B end-to-end.

## 8. Known gaps / risks to remember

- **No etcd encryption-at-rest** on hardway (apiserver has no `--encryption-provider-config`). Secrets (incl. the Flux deploy key private half) sit **plaintext in etcd** — we proved this by reading it. Mitigation here = the deploy key is **read-only + single-repo**. Hardening options noted in cheat-sheet (KMS/EncryptionConfiguration, SOPS, External Secrets, RBAC). A **fragment of the read-only deploy private key appeared in this session's logs**; low risk (read-only, one private repo), can rotate via re-bootstrap if desired.
- The 3 cluster fixes in §3 are **not captured as code**. If the cluster is rebuilt, they must be re-applied (or, better, baked into provisioning). Consider documenting them in the local `flux-gpu-trainer` repo.
- `git` CLI output is mangled by the rtk hook — don't trust its stdout; verify via `.git/` files or k8s tooling.

## 9. User preferences (from global CLAUDE.md)

- **Be extremely concise**; sacrifice grammar for concision. Explanations welcome (teaching), but tight.
- **NEVER use the AskUserQuestion multiple-choice tool.** Ask questions inline as plain text; bulleted options OK but keep open-ended.
- End plans with a concise list of unresolved questions. Split large plans into phases. Create a GitHub issue capturing plan state when asked / when context runs low.
- Language: **TypeScript on node v22**; package manager **yarn**; GitHub via **gh CLI**.
- Pulumi: always `PULUMI_CONFIG_PASSPHRASE=""`.
- Commit message trailer used this session: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## 10. Conceptual ground already covered (don't re-teach unless asked)

**Foundations (session 1):** GitOps reconciliation model; bootstrap (one-time imperative seed) vs ongoing pull-based reconcile; `gotk-components.yaml` vs `gotk-sync.yaml`; deploy key vs HTTPS token (two creds); repo anatomy (clusters vs infrastructure vs apps; why flux-system lives in clusters/); kustomize base/overlay; the **two `kind: Kustomization`** (apiGroup `kustomize.config.k8s.io` = plain build file vs `kustomize.toolkit.fluxcd.io` = Flux reconciler); auto-scan (no kustomization.yaml) vs allowlist (has one); Terraform↔Flux mental mapping (modules≈bases, patches-not-inputs, continuous-reconcile-not-apply, no state file, prune≈destroy); how fleets bootstrap at scale (IaC/CAPI/flux-operator, "born GitOps-managed", hub-spoke); why Baseten is multi-cloud (GPU scarcity → bin-pack to ~95% util, NOT elastic autoscaling) and that the portable layer (Flux + GPU Operator) matters more than EKS/Karpenter specifics.

**Today (session 2):**
- **HelmRelease + OCIRepository**: source-controller fetches OCI artifact via `OCIRepository` → produces in-cluster artifact at `http://source-controller.flux-system.svc.cluster.local`; helm-controller fetches that → runs `helm install`. `chartRef:` (modern, for OCI/Git) vs `chart.spec.sourceRef:` (classic, HelmRepository catalog lookup). Why OCI: one auth/mirror surface, cosign-signable, immutable digests. Modern Baseten-shape default.
- **Cross-namespace `valuesFrom`**: HR in `gpu-operator` references CM by **static name** that lives in cluster overlay. Same name in every cluster overlay → different content → per-cluster values without forking the HR.
- **The Import-Trap of `prune: true`**: when Flux patches a pre-existing resource (e.g. Node) via SSA, that resource enters Flux's inventory. `git rm` → next reconcile prune-deletes the resource. For Nodes, that means `kubectl delete node` → eviction storm → kubelet re-registers blank → labels gone. Mitigation: `kustomize.toolkit.fluxcd.io/prune: disabled` annotation. Same shape as Pulumi `import` + `pulumi destroy`; fix is `protect: true` in Pulumi, this annotation in Flux. **Use on any pre-existing or co-owned resource** (Nodes, kube-system ns, default ns, default SAs, vendor CRDs).
- **SSA field ownership**: every resource has a `managedFields` array tracking per-key ownership across managers (`kubelet`, `cilium-operator-generic`, `kube-controller-manager`, `kustomize-controller`, etc.). Maps (labels/annotations) tracked per-key; some lists atomic. `Apply` op (SSA) coexists with `Update` op (legacy clients). Conflicts when two managers claim same key → SSA refuses unless `force` set. Inspect via `kubectl get <obj> --show-managed-fields -o yaml`.
- **Composition vs overlay (kustomize)**: Pulling `resources:` from a base path is composition — base resources pass through unchanged. *Overlay* requires a transformer (`patches:`, `replicas:`, `images:`, `namespace:`, `namePrefix:`, `commonLabels:`) that *modifies* what was pulled in. `replicas:` and friends are sugar over `patches:`. Our `apps/hardway/` got its first real overlay via `replicas:`.
- **Cross-Flux-Kustomization ordering**: `dependsOn:` gates reconcile-start; `wait: true` on the depended-on Kustomization makes "Ready" mean "all resources health-pass." Together: GPU operator's DaemonSets must be Ready before any apps requesting `nvidia.com/gpu` reconcile.
- **GPU scheduling end-to-end**: pod requests `nvidia.com/gpu: 1` + `nodeSelector: nvidia.com/gpu.product=...` → kube-scheduler picks node with capacity + matching label → kubelet asks device-plugin (gRPC over unix socket) "allocate 1 GPU" → device-plugin returns UUID + env vars → kubelet injects into pod env → container sees `MOCK_NVIDIA_VISIBLE_DEVICES=...`. On real hardware the chain is identical; only the device-plugin's allocation logic is different.
- **`flux diff kustomization`** is the right preview tool (not `kubectl diff` from outside Flux, which false-positives on Flux's ownership-label transformer). Exits non-zero on any drift — wire into CI as a gate.
- **Readiness gates**: `spec.readinessGates` lets external controllers vote into pod Ready. Direction: gate is from the LB controller INTO k8s readiness state (not from k8s into the LB). Prevents rolling-deploy 502s by making Deployment wait to kill old pods until ALB confirms new ones are in rotation. Baseten-relevant for model-warmup gates (don't route inference traffic until weights loaded + JIT warmed).
