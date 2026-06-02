# HANDOFF — flux-gpu-trainer / fleet-infra

> Cold-session pickup doc. Strictly what's needed to resume, no exhaustive teaching log.
> Companion: `docs/CHEATSHEET.md` (concepts + command reference). Update both when state changes meaningfully.

---

## 0. TL;DR — current state (2026-06-02, end of session 4)

**Project:** the user got a job at **Baseten** (AI inference, NVIDIA GPUs across 15+ clouds). Hands-on prep to fluency in **Flux/GitOps**, **GPU scheduling / NVIDIA GPU Operator**, **Terraform-driven multi-cloud provisioning**. User knows k8s + Argo CD + AWS well; gaps are Flux + GPU + cloud-agnostic IaC.

**Mode:** TEACHING. Explain the "why" inline as we build. Be concise; user reads everything you write.

**Tracks:**
- **Track A — hardway cluster** (OrbStack arm64 VMs): ✓ COMPLETE. Flux v2.8.8 healthy; fake-gpu-operator advertising 4 simulated H100s; gpu-demo Deployment bin-packing 4 replicas across 2 workers. End-to-end fake-GPU scheduling proven.
- **Track B — aws-gpu cluster** (real AWS A10G): **EVERYTHING DESTROYED, ready for a clean rebuild on the corrected design.** This session: rebuilt on k3s 1.33.12 (on-demand — spot capacity was exhausted in us-west-2a), installed the real GPU Operator → **it took the node NotReady** (operator's container-toolkit is incompatible with k3s 1.33's containerd 2.x). Diagnosed + hand-recovered + **proved the A10G works end-to-end (`nvidia-smi` in a pod: A10G, driver 580.126.20, CUDA 13.0)**, then **redesigned to the robust k3s pattern (Path A)** and committed it. Then destroyed both stacks to step away.

**Immediate next step:** rebuild Track B with the corrected design (see §7) — `terraform apply` infra → flux-bootstrap, `git pull`, verify the operator comes up **device-plugin-only** (driver+toolkit host-managed), re-run the `nvidia-smi` smoke test, then scaffold `apps/aws-gpu` + vLLM.

---

## 1. Paths that matter

### Repos
- **Workbench (LOCAL ONLY, never pushed):** `/Users/dbilleci/Development/slikk66/flux-gpu-trainer/`
  - `k8s-hardway/` — hardway PKI/scripts + admin.kubeconfig
  - `iac/aws-gpu/{infra,flux-bootstrap}/` — Track B Terraform stacks
  - `.env` — currently has `TF_VAR_github_token` (only used if Option B path; we use Option A — see secrets below)
- **GitOps repo (private, on GitHub):** `/Users/dbilleci/Development/slikk66/fleet-infra/` → `git@github.com:slikk66/fleet-infra` (branch `main`)

### KUBECONFIGs
- **hardway:** `export KUBECONFIG=/Users/dbilleci/Development/slikk66/flux-gpu-trainer/k8s-hardway/admin.kubeconfig`
- **aws-gpu:** `export KUBECONFIG=/Users/dbilleci/Development/slikk66/flux-gpu-trainer/iac/aws-gpu/infra/.local/kubeconfig` (regenerated each `terraform apply`)

### Secrets / state
- **Terraform state:** S3 bucket `billeci-state-upgraded` (us-west-2), native S3 locking (no DynamoDB needed since TF 1.11). Keys: `terraform/aws-gpu/{infra,flux-bootstrap}/terraform.tfstate`.
- **GitHub PAT (fine-grained, scoped to `slikk66/fleet-infra`, Contents R/W + Administration R/W):** `iac/aws-gpu/flux-bootstrap/terraform.tfvars` (auto-loaded by Terraform, gitignored, mode 600).
- **SSH key for aws-gpu EC2:** `iac/aws-gpu/infra/.local/ssh_key` (TLS-generated, gitignored).

### Tooling
- `flux` v2.8.8 — required for both clusters
- `kubectl` v1.35.3, `kustomize` v5.8.1
- `terraform` v1.14.7 (latest is 1.15.5; ours is fine — native S3 locking shipped in 1.11)
- `gh` authed as `slikk66`

---

## 2. The "rtk" git hook caveat

A `rtk` shell hook mangles `git` CLI stdout. Plain `git add/commit/push` still works (via Bash tool), but **never trust git's printed output**. To verify git state, read `.git/HEAD`, `.git/refs/heads/main`, or use `flux`/`kubectl` for downstream verification.

---

## 3. Cluster: hardway

- "Kubernetes the hard way" on OrbStack Ubuntu 24.04 arm64 VMs. k8s **v1.35.3**. Cilium CNI w/ kube-proxy replacement.
- Nodes: `control-1` 192.168.139.92 (apiserver only, NOT a registered node) · `worker-1` 192.168.139.161 · `worker-2` 192.168.139.68.
- Service CIDR `10.32.0.0/24` (DNS `10.32.0.10`), Pod CIDR `10.200.0.0/16`.

**Three cluster-level fixes are NOT in git** (would need re-apply on cluster rebuild):
1. ClusterRole `system:kube-apiserver-to-kubelet` + binding (RBAC apiserver→kubelet/proxy).
2. apiserver `--advertise-address=192.168.139.92` (was 127.0.0.1, broke service ClusterIP). Edit at `/etc/systemd/system/kube-apiserver.service` on control-1; backup at `.bak`.
3. CoreDNS initially seeded via `kubectl apply` (chicken-and-egg: Flux needs DNS to clone repo). Now in git at `infrastructure/controllers/base/coredns/`, Flux adopted via SSA.

**Healthy state:**
```bash
flux get kustomizations  # flux-system, infrastructure, apps — all READY=True
flux get helmreleases -A # gpu-operator/fake-gpu-operator READY=True
flux get sources oci -A  # flux-system/fake-gpu-operator READY=True
kubectl get nodes -L nvidia.com/gpu.product,nvidia.com/gpu.count   # 2x NVIDIA-H100-80GB-HBM3 per worker
```

---

## 4. Cluster: aws-gpu (Track B) — CURRENTLY DESTROYED

- Single-node k3s on EC2 g5.xlarge (real A10G GPU, 24GB) in us-west-2a. Provisioned via Terraform.
- **Two stacks**, separate state files:
  - `iac/aws-gpu/infra/` — VPC, EC2, IAM (S3 read on `models/*`), k3s via cloud-init. State currently EMPTY (destroyed).
  - `iac/aws-gpu/flux-bootstrap/` — deploy key + `flux_bootstrap_git` (canonical Flux+TF pattern: SSH-only, writeable deploy key; PAT only consumed by github provider). State EMPTY (destroyed).
- **Reconcile target:** `clusters/aws-gpu/` — flux-bootstrap commits `flux-system/` here, and our committed `infrastructure.yaml` auto-activates (flux-system syncs `./clusters/aws-gpu`). No `apps.yaml` yet (deferred until operator verified).
- **k3s = v1.33.12+k3s1** (`local.k3s_version` in `k3s.tf`). Ships **containerd 2.2.3** (CRI `v1` schema) — this matters, see below.
- **k3s install knobs (user_data):** `--disable=traefik --disable=servicelb --write-kubeconfig-mode 644 --tls-san <public-ip-via-IMDS> --node-label nvidia.com/gpu.deploy.gpu-operator=true`.

**On-demand, not spot (this session):** spot capacity for g5.xlarge in us-west-2a was exhausted (`RunInstances` looped silently on `InsufficientInstanceCapacity` — no instance, no spot request, just "Still creating"). Spot price that day was ~$0.63/hr (up from the old ~$0.30). **`instance_market_options` block in `compute.tf` is now COMMENTED OUT** → on-demand (~$1.21/hr). Uncomment to retry spot when capacity returns.

**⚠️ THE BIG LESSON — GPU Operator's toolkit breaks k3s 1.33:**
- The operator's bundled container-toolkit (v1.19.1 in chart v26.3.2) rewrote k3s's containerd config in the **old `version=2` / `io.containerd.grpc.v1.cri` schema** AND replaced k3s's monolithic config (dropping the inline **CNI** `bin_dir`/`conf_dir`). k3s 1.33 uses containerd 2.x = **CRI `v1` (`io.containerd.cri.v1`)**. Result: CNI never initialized → **node NotReady, every pod failing** `cni plugin not initialized`.
- **Fix = Path A (host-managed driver + toolkit; committed):** cloud-init installs the NVIDIA driver (`cuda-drivers`) + `nvidia-container-toolkit` **before** k3s. k3s then **natively detects** `nvidia-container-runtime` and writes a correct, CNI-safe containerd config itself (with `nvidia` + `nvidia-cdi` runtimes + a built-in `nvidia` RuntimeClass). The GPU Operator runs with **`driver.enabled=false` + `toolkit.enabled=false`** → only NFD/GFD/device-plugin/dcgm/validators.
- Why not operator-managed: operator-everything is genuinely incompatible with this k3s/containerd combo without fragile hacks. Host driver+toolkit + operator-device-plugin is the canonical k3s GPU recipe.

**Healthy state (after the corrected rebuild):**
```bash
export KUBECONFIG=/Users/dbilleci/Development/slikk66/flux-gpu-trainer/iac/aws-gpu/infra/.local/kubeconfig
kubectl get nodes -o wide                 # 1 node, v1.33.12+k3s1, Ready
kubectl get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'  # 1
flux check; flux get kustomizations        # all green, infrastructure READY=True
kubectl get pods -n gpu-operator           # NO nvidia-driver-daemonset / nvidia-container-toolkit-daemonset
                                           # (those are host-managed now); device-plugin/gfd/dcgm/validator Running
# smoke test (proved working last session):
kubectl run smi --rm -it --restart=Never --image=nvcr.io/nvidia/cuda:12.4.0-base-ubuntu22.04 \
  --overrides='{"spec":{"runtimeClassName":"nvidia","containers":[{"name":"smi","image":"nvcr.io/nvidia/cuda:12.4.0-base-ubuntu22.04","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":1}}}]}}'
```

---

## 5. Repo layout (fleet-infra)

```
clusters/
├── hardway/
│   ├── flux-system/                # bootstrap output (DO NOT EDIT)
│   ├── infrastructure.yaml         # → infrastructure/controllers/hardway
│   └── apps.yaml                   # → apps/hardway, dependsOn [infrastructure], wait: true
└── aws-gpu/
    ├── flux-system/                # committed by Terraform's flux_bootstrap_git (re-created on rebuild)
    └── infrastructure.yaml         # → infrastructure/controllers/aws-gpu (timeout 10m). COMMITTED.
                                    # apps.yaml NOT created yet (deferred until operator verified)

infrastructure/
├── sources/base/
│   ├── kustomization.yaml          # resources: runai-oci.yaml, nvidia-helm.yaml
│   ├── runai-oci.yaml              # OCIRepository for ghcr.io/run-ai/fake-gpu-operator @ 0.0.81
│   └── nvidia-helm.yaml            # HelmRepository nvidia → https://helm.ngc.nvidia.com/nvidia (public, no NGC token)
└── controllers/
    ├── base/
    │   ├── coredns/                # for hardway only; aws-gpu uses k3s's built-in coredns
    │   ├── fake-gpu-operator/      # Namespace + HelmRelease (shared base for hardway)
    │   │   ├── namespace.yaml
    │   │   ├── helmrelease.yaml    # chartRef → OCIRepository; valuesFrom CM fake-gpu-operator-values
    │   │   └── kustomization.yaml
    │   └── nvidia-gpu-operator/    # REAL operator (shared base for real-GPU clusters)
    │       ├── namespace.yaml      # ns gpu-operator
    │       ├── helmrelease.yaml    # chart gpu-operator v26.3.2 from HelmRepository nvidia; valuesFrom CM
    │       └── kustomization.yaml
    ├── hardway/
    │   ├── kustomization.yaml
    │   ├── gpu-nodes.yaml          # Node SSA-patches, prune-disabled
    │   └── fake-gpu-operator-values.yaml  # ConfigMap: 2x H100-80GB-HBM3, 81559 MiB
    └── aws-gpu/
        ├── kustomization.yaml      # ../../sources/base + ../base/nvidia-gpu-operator + values CM
        └── nvidia-gpu-operator-values.yaml  # ConfigMap: driver.enabled=false + toolkit.enabled=false
                                              # (host owns driver+toolkit; see §4). NO gpu-nodes.yaml —
                                              # NFD/GFD discover the real GPU.

apps/
├── base/gpu-demo/                  # busybox + nvidia.com/gpu:1 + H100 nodeSelector
└── hardway/                        # replicas: 4 transformer (first real overlay)
                                    # (apps/aws-gpu NOT created yet — smoke test / vLLM go here)
```

---

## 6. Decisions locked

- **IaC tool:** **Terraform** (confirmed: Baseten uses Terraform; Pulumi was considered and dropped).
- **Terraform state backend:** S3 `billeci-state-upgraded` (us-west-2) with **native S3 locking** (`use_lockfile = true`). No DynamoDB.
- **Stack split:** infra/ and flux-bootstrap/ have separate state files. flux-bootstrap reads infra outputs via `data "terraform_remote_state"` (read-only). Avoids the diff-churn footgun where TF and Flux both want to manage gotk-* resources.
- **Cross-stack convention:** infra outputs use `abspath()` for filesystem paths so flux-bootstrap can resolve them from a different working dir.
- **Flux bootstrap auth (Track B):** SSH-only (writeable deploy key). PAT consumed once by the `github` provider to create the key, then never used again.
- **Repo split:** workbench (`flux-gpu-trainer`) never pushed; GitOps repo (`fleet-infra`) is the source of truth.
- **Region:** us-west-2 for everything (state bucket, EC2, model staging).
- **aws-gpu billing model: on-demand** (~$1.21/hr). Spot capacity for g5.xlarge in us-west-2a was unavailable; `instance_market_options` in `compute.tf` is commented out. Revisit spot later.
- **GPU on k3s = host-managed driver + toolkit (cloud-init), operator device-plugin-only.** Forced by k3s 1.33's containerd 2.x vs the operator toolkit's old CRI schema (§4). NOT operator-managed driver (the earlier plan — reversed after it broke the node).
- **NVIDIA chart source = HelmRepository** (NGC `helm.ngc.nvidia.com/nvidia`, public), NOT OCIRepository — nvcr.io's OCI chart registry now 403s without an NGC token. (Component images still pull anonymously from nvcr.io/nvidia.) GPU Operator pinned **v26.3.2**.

---

## 7. NEXT STEPS

> The infra/apps GitOps scaffolding + GPU Operator base are DONE and committed (HEAD `51bc558`).
> The design is corrected (Path A). The work left is: rebuild → verify → smoke test → vLLM.

0. **Sync local git first.** Local `main` = `51bc558` is **1 behind** origin `597e995` (the flux-bootstrap-destroy commit that removed `clusters/aws-gpu/flux-system/`; the dir is stale locally). Run:
   ```bash
   cd /Users/dbilleci/Development/slikk66/fleet-infra && git pull --ff-only origin main
   ```

1. **Rebuild Track B** (everything is destroyed; AWS creds = `AWS_PROFILE=billeci`, SSO). Order MATTERS:
   ```bash
   cd /Users/dbilleci/Development/slikk66/flux-gpu-trainer/iac/aws-gpu/infra
   AWS_PROFILE=billeci terraform apply        # new cloud-init: driver(cuda-drivers)+toolkit BEFORE k3s.
                                              # First boot ~3-4 min LONGER (DKMS build). Watch wait_for_k3s.
   cd ../flux-bootstrap && AWS_PROFILE=billeci terraform apply   # re-bootstraps; auto-reads terraform.tfvars
   cd /Users/dbilleci/Development/slikk66/fleet-infra && git pull --ff-only origin main   # re-added gotk files
   ```
   New instance = **fresh public IP**; kubeconfig at `.local/kubeconfig` is re-fetched by `terraform_data.kubeconfig`.

2. **Verify (the whole point of the rebuild — confirm the fix holds):** see §4 "Healthy state". Key checks:
   - node `Ready` immediately + STAYS Ready (the old break took it NotReady ~3 min after operator install).
   - `kubectl get pods -n gpu-operator` has **NO** `nvidia-driver-daemonset` / `nvidia-container-toolkit-daemonset`.
   - `nvidia.com/gpu` allocatable = 1; on the node, `nvidia-smi` works (driver from cloud-init).
   - If cloud-init driver install failed, `wait_for_k3s` times out → SSH in (`.local/ssh_key`, `ubuntu@<ip>`), check `cloud-init` logs (`sudo cat /var/log/cloud-init-output.log`) + `nvidia-smi`.

3. **GPU smoke test** (already proved working once — re-confirm after clean rebuild): see the `kubectl run smi` one-liner in §4. Expect A10G / driver 580.x / CUDA 13.0.

4. **Scaffold the apps tier** (deferred this session): create `clusters/aws-gpu/apps.yaml` (→ `apps/aws-gpu`, dependsOn [infrastructure], wait: true) + `apps/aws-gpu/` overlay. Start with the smoke-test pod as a managed app, then vLLM.

5. **Real inference workload:** vLLM serving Phi-3-mini-4k-instruct (~7.6GB, fits in A10G's 24GB). Model staged at `s3://billeci-state-upgraded/models/microsoft/Phi-3-mini-4k-instruct/`; init container does `aws s3 sync` into a PV (node IAM role already has S3 read on `models/*`). PVC + Service + port-forward to test.

6. **Sprinkles (after Track B end-to-end):** SOPS for a secret, image-automation, Alert/Provider for Slack.

---

## 8. Known risks / gotchas

- **Cost meter:** aws-gpu g5.xlarge is **~$1.21/hr on-demand** (currently on-demand; spot was unavailable). `terraform destroy` BOTH stacks (flux-bootstrap first) when stepping away. **It is currently fully destroyed — $0/hr.**
- **GPU Operator toolkit vs k3s 1.33 (the session-4 trap):** do NOT re-enable `driver`/`toolkit` in the operator on k3s — it rewrites containerd in the wrong CRI schema and kills CNI → node NotReady. Host owns driver+toolkit; operator is device-plugin-only. (Full diagnosis in §4.)
- **DKMS in cloud-init:** the driver now builds via `cuda-drivers` DKMS at first boot (~3-4 min). If `terraform apply` hangs on `wait_for_k3s`, the driver build likely failed — SSH in and read `/var/log/cloud-init-output.log`. Module is `modprobe`'d (no reboot); if a kernel/driver mismatch ever forces a reboot, the marker-file logic in `k3s.tf` would need adjusting.
- **Spot capacity (us-west-2a):** g5.xlarge spot was exhausted this session — `RunInstances` loops silently on `InsufficientInstanceCapacity` (no instance, no spot request, just "Still creating"). If retrying spot, watch for that signature; fall back to on-demand by leaving `instance_market_options` commented.
- **No etcd encryption-at-rest on hardway** (apiserver lacks `--encryption-provider-config`). Deploy key sits plaintext in etcd. Mitigation: deploy key is read-only + scoped to one repo.
- **Hardway cluster fixes (§3) are NOT in git.** If cluster is rebuilt, the three fixes must be re-applied manually.
- **k3s `--tls-san` only includes the public IP at install time.** New public IP on rebuild → kubeconfig re-fetched by the `terraform_data.kubeconfig` resource on apply.

---

## 9. User preferences

- **Be extremely concise**; sacrifice grammar for brevity. Teaching welcome but tight.
- **NEVER use the AskUserQuestion multiple-choice tool.** Plain text questions inline, bullets OK.
- End plans with a concise list of unresolved questions.
- Language: TypeScript on node v22; package manager yarn; GitHub via gh CLI.
- Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## 10. Conceptual ground covered → in cheatsheet, not here

Don't re-teach unless asked. `docs/CHEATSHEET.md` covers: GitOps reconciliation, HelmRelease/OCIRepository, SSA field ownership + prune-disabled pattern, kustomize composition vs overlay, dependsOn/wait ordering, GPU scheduling chain, `flux diff`, readiness gates.

**Not yet in cheatsheet (session 3 covered):** Terraform native S3 locking, two-stack split with `terraform_remote_state` cross-stack refs, canonical Flux+TF SSH-only bootstrap (writeable deploy key; PAT consumed once by github provider).

**Not yet in cheatsheet (session 4 covered):**
- **NFD vs GFD vs nvidia-smi**, and the GPU Operator's "discover → operator stamps `nvidia.com/gpu.deploy.*` labels → operands schedule" two-step. declare-vs-discover (fake hand-labels nodes; real hardware is discovered).
- **GPU Operator on k3s gotcha:** operator toolkit writes CRI-v2 schema + guts k3s's inline CNI config → containerd 2.x (k3s 1.33) breaks. Fix: host driver+toolkit, k3s native nvidia-runtime detection, operator device-plugin-only.
- **HelmRepository (NGC) vs OCIRepository (nvcr.io 403)**; HelmRelease `chart.spec` (HTTP repo) vs `chartRef` (OCI) forms.
- **Spot `InsufficientInstanceCapacity`** silent-retry signature; on-demand fallback via commenting `instance_market_options`.
- **rtk caveat extends beyond git:** it also truncates/mangles `helm`, `aws`, `kubectl`, `grep`, `wc` stdout. Use `rtk proxy <cmd>` for raw output, or call binaries by absolute path (`/usr/bin/grep`, `$(which aws)`); use the Read tool for files.

Worth adding all of the above to cheatsheet at a natural break.
