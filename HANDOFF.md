# HANDOFF — flux-gpu-trainer / fleet-infra

> Read this top-to-bottom before doing anything. It lets a cold agent resume exactly where we are.
> Companion doc: `docs/CHEATSHEET.md` (teaching log + Flux/Kustomize reference). Keep both updated.

---

## 0. TL;DR — current state (2026-05-29)

- **Goal:** the user got a job at **Baseten** (AI inference, NVIDIA GPUs across 15+ clouds + bare-metal colos). This is a **hands-on learning exercise** to get fluent in **Flux (GitOps)**, **GPU scheduling / NVIDIA GPU Operator**, and **cloud-agnostic provisioning**. The user knows k8s + Argo CD + AWS well; Flux and GPU scheduling are the gaps.
- **This is a TEACHING engagement.** The user is going concept-by-concept and wants explanations *as we build*, not just execution. Match that: explain the "why," correct misconceptions directly, keep answers concise.
- **Where we are:** Flux is **bootstrapped and fully healthy** on the local "hardway" cluster, reconciling from `github.com/slikk66/fleet-infra`. CoreDNS is GitOps-managed. We just finished a long teaching deep-dive on Flux/Kustomize repo mechanics. **Next planned step: install the GPU Operator via a `HelmRelease`** (fake-gpu-operator first on hardway), then a GPU-scheduled app with `apps dependsOn infrastructure`.

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
- `flux get kustomizations` → `flux-system` and `infrastructure` both `READY=True` at `main@sha1:3ac3eb47`.

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

## 5. Repo layout (fleet-infra @ commit 3ac3eb47)

```
clusters/hardway/
├── flux-system/                  # bootstrap output (DO NOT EDIT): gotk-components.yaml, gotk-sync.yaml, kustomization.yaml
└── infrastructure.yaml           # Flux Kustomization → path infrastructure/controllers/hardway (prune+wait)
infrastructure/controllers/
├── base/coredns/                 # coredns.yaml + kustomization.yaml (shared base)
└── hardway/kustomization.yaml    # overlay → ../base/coredns
docs/CHEATSHEET.md                # teaching log + Flux/Kustomize/Terraform-mapping reference
HANDOFF.md                        # this file
```
Reconcile chain: root Kustomization (gotk-sync.yaml, `path: ./clusters/hardway`) → auto-scan picks up `flux-system/` + `infrastructure.yaml` → `infrastructure.yaml` points to `infrastructure/controllers/hardway` → `../base/coredns`.

### Uncommitted working-tree changes (commit these or fold into next work)
- `docs/CHEATSHEET.md` — expanded with the Flux deep-dive + CoreDNS-adoption update (edited after commit 3ac3eb47).
- `HANDOFF.md` — this new file.

## 6. Decisions locked

- **Repos:** local workbench (`flux-gpu-trainer`, never pushed) + GitHub GitOps repo (`fleet-infra`). Two-repo split.
- **Monorepo GitOps layout:** `clusters/<name>/` entrypoints + `infrastructure/` + `apps/`, base+overlay. One dir per cluster; the binding to a cluster is the Flux root Kustomization's `spec.path`, not the dir name.
- **Track B (real GPU):** AWS, **us-west-2** (fallback us-east-2), **g5.xlarge (A10G) spot**, **k3s** single-node (NOT EKS — deliberately bare-metal-shaped), real NVIDIA GPU Operator. Provision with **Pulumi + TypeScript**, **S3 state backend**, `PULUMI_CONFIG_PASSPHRASE=""`. Flux installed on it via the **Pulumi/Terraform Flux provider** (automated bootstrap = the prod-shaped exercise). Reconciles `clusters/aws-gpu/` from the same fleet repo.
- **Auth:** gh token for the manual Track A bootstrap (done); use a **fine-grained PAT** for Track B's IaC-driven bootstrap.

## 7. NEXT STEPS (in order)

1. **Commit the uncommitted cheat-sheet + this handoff.**
2. **GPU Operator via HelmRelease (the big unlearned pattern).** Add `infrastructure/controllers/base/<op>` + a `HelmRepository`/`OCIRepository` + `HelmRelease`. Start with **run-ai/fake-gpu-operator** (or `kind-gpu-sim`) on hardway to learn GPU scheduling *without* real hardware (it advertises `nvidia.com/gpu` via KWOK; label nodes per its README). Explain HelmRelease/HelmRepository model as you go.
3. **`apps/` layer + ordering.** Add `clusters/hardway/apps.yaml` (Flux Kustomization) with **`dependsOn: [infrastructure]`** and `wait: true`. Add a GPU-scheduled demo pod (`resources.limits: nvidia.com/gpu: 1`, plus taints/tolerations/nodeSelector). Watch Flux order infra→apps.
4. **Per-cluster customization:** demonstrate `postBuild.substituteFrom` and/or a kustomize `patches:`/`replicas:`/`images:` overlay so `hardway` vs `aws-gpu` differ from a shared base.
5. **Track B:** Pulumi TS to provision the g5 spot box + k3s + IaC Flux bootstrap + real GPU Operator + a real CUDA/vLLM workload. Tear down with `pulumi destroy` to control cost.
6. **Sprinkles when ready:** SOPS for a secret; image-automation for a model-server image; an Alert/Provider for Slack.

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

GitOps reconciliation model; bootstrap (one-time imperative seed) vs ongoing pull-based reconcile; `gotk-components.yaml` vs `gotk-sync.yaml`; deploy key vs HTTPS token (two creds); repo anatomy (clusters vs infrastructure vs apps; why flux-system lives in clusters/); kustomize base/overlay; the **two `kind: Kustomization`** (apiGroup `kustomize.config.k8s.io` = plain build file vs `kustomize.toolkit.fluxcd.io` = Flux reconciler); auto-scan (no kustomization.yaml) vs allowlist (has one); Terraform↔Flux mental mapping (modules≈bases, patches-not-inputs, continuous-reconcile-not-apply, no state file, prune≈destroy); how fleets bootstrap at scale (IaC/CAPI/flux-operator, "born GitOps-managed", hub-spoke); why Baseten is multi-cloud (GPU scarcity → bin-pack to ~95% util, NOT elastic autoscaling) and that the portable layer (Flux + GPU Operator) matters more than EKS/Karpenter specifics.
