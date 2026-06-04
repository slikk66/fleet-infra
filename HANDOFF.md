# HANDOFF — flux-gpu-trainer / fleet-infra

> Cold-start pickup doc. What's needed to resume, not a history log.
> Companion: `docs/CHEATSHEET.md` (concepts + commands, through session 5). Update both when state changes.

---

## 0. Current state (end of session 5, 2026-06-03)

**Project:** user starts at **Baseten** (~2026-06-09) — AI inference, NVIDIA GPUs across 15+ clouds. Role: **cloud platform** (Flux + Terraform + the global multi-cluster manager / "MCM"). Hands-on prep to fluency in Flux/GitOps, GPU scheduling, multi-cloud IaC. Mode: **TEACHING** — explain the "why"; user reads everything, asks pointed follow-ups.

**Track A — hardway** (OrbStack arm64 VMs): UP and healthy. Flux v2.8.8, all kustomizations READY. fake-gpu-operator advertising H100s, gpu-demo bin-packing. **NEW this session: live SOPS+age secret** (see §6). Local/free — fine to leave running.

**Track B — aws-gpu** (real AWS A10G): **fully DESTROYED ($0/hr).** This session it was **fully proven end-to-end** on the corrected design: Path A + instance-store NVMe → vLLM serving Phi-3-mini over the OpenAI API (buffered + streaming), reachable from the laptop via NodePort. Then destroyed. Rebuild is now a known, clean dance (§7).

**The main learning arc (Flux + GPU + Terraform + real inference) is DONE.** Forward work is prep exercises (§8), not unfinished plumbing.

---

## 1. Paths

### Repos
- **Workbench (LOCAL ONLY, never pushed):** `/Users/dbilleci/Development/slikk66/flux-gpu-trainer/`
  - `k8s-hardway/` — hardway PKI + `admin.kubeconfig`; **`.sops/age.agekey`** (age private key, mode 600)
  - `iac/aws-gpu/{infra,flux-bootstrap}/` — Track B Terraform. **Edits this session live on disk here, uncommitted (workbench isn't git-tracked for push) — they ARE the current source of truth for the infra.**
- **GitOps repo (pushed):** `/Users/dbilleci/Development/slikk66/fleet-infra/` → `git@github.com:slikk66/fleet-infra` (branch `main`). **HEAD = `256ea9a`, clean.**

### KUBECONFIGs
- **hardway:** `/Users/dbilleci/Development/slikk66/flux-gpu-trainer/k8s-hardway/admin.kubeconfig`
- **aws-gpu:** `/Users/dbilleci/Development/slikk66/flux-gpu-trainer/iac/aws-gpu/infra/.local/kubeconfig` (re-fetched on each infra apply; new IP every rebuild)

### Secrets / state
- **Terraform state:** S3 `billeci-state-upgraded` (us-west-2), native S3 locking. Keys: `terraform/aws-gpu/{infra,flux-bootstrap}/terraform.tfstate`. **Both empty (destroyed).**
- **GitHub PAT** (fine-grained, `slikk66/fleet-infra`, Contents+Administration R/W): `iac/aws-gpu/flux-bootstrap/terraform.tfvars` (gitignored, mode 600).
- **age keypair (SOPS):** private at `flux-gpu-trainer/k8s-hardway/.sops/age.agekey`; public recipient `age1u4zkw3fuzlf6rjafrcwphsvl57nlwawue24fehd2mahny946py6s5h9269` (in `.sops.yaml`). In-cluster copy: `Secret flux-system/sops-age` on hardway.
- **AWS:** `AWS_PROFILE=billeci` (SSO; acct 761425999210). Re-auth if `sts get-caller-identity` fails.

### Tooling
`flux` v2.8.8 · `kubectl` v1.35.3 · `kustomize` v5.8.1 · `terraform` v1.14.7 · `sops` v3.13.1 + `age` v1.3.1 · `gh` (slikk66).

---

## 2. The rtk caveat
A `rtk` shell hook mangles stdout for `git`, `helm`, `aws`, `kubectl`, `grep`, `wc`, **`curl`**. Don't trust their printed output. Use `rtk proxy <cmd>` for raw, call binaries by absolute path (`/usr/bin/grep`, `/usr/bin/curl`), or use the Read tool for files. To verify git, read `.git/refs/heads/main`.

---

## 3. Track A: hardway

- "k8s the hard way" on OrbStack Ubuntu arm64 VMs. k8s v1.35.3, Cilium CNI. control-1 `192.168.139.92` (apiserver, not a node) · worker-1 `192.168.139.161` · worker-2 `192.168.139.68`. Service CIDR `10.32.0.0/24` (DNS `.10`), Pod CIDR `10.200.0.0/16`.
- **3 cluster-fixes NOT in git** (re-apply if cluster rebuilt): (1) ClusterRole `system:kube-apiserver-to-kubelet` + binding; (2) apiserver `--advertise-address=192.168.139.92` (edit `/etc/systemd/system/kube-apiserver.service` on control-1, `.bak` exists); (3) CoreDNS bootstrap seed (now in git, Flux adopted).
- **SOPS+age (live):** `apps/hardway/demo.secret.yaml` is SOPS-encrypted; hardway `apps` Kustomization has `decryption: {provider: sops, secretRef: sops-age}`; Flux decrypts → `Secret gpu-apps/demo-credentials` (cleartext) in-cluster. To edit: `sops apps/hardway/demo.secret.yaml`. To view: `SOPS_AGE_KEY_FILE=…/.sops/age.agekey sops -d apps/hardway/demo.secret.yaml`.

Healthy check: `flux get kustomizations` (all READY) · `flux get helmreleases -A`.

---

## 4. Track B: aws-gpu — DESTROYED, design PROVEN

Single-node k3s **v1.33.12+k3s1** on EC2 **g5.xlarge** (A10G 24GB), us-west-2a, on-demand (~$1.21/hr). Two TF stacks, separate state: `infra/` (VPC/EC2/IAM/k3s) and `flux-bootstrap/` (deploy key + flux). Flux target path `clusters/aws-gpu/`.

**Design (all proven working this session):**
- **GPU = host-managed driver+toolkit (cloud-init), operator device-plugin-only** (`driver.enabled=false`+`toolkit.enabled=false`). k3s natively detects nvidia-container-runtime → `nvidia` RuntimeClass. Forced by k3s 1.33 containerd 2.x vs the operator toolkit's old CRI schema (would take node NotReady). Driver built ~610.43.02 via `cuda-drivers` DKMS.
- **Instance-store NVMe for images + model cache.** g5 ships a ~250GB ephemeral NVMe (`nvme1n1`). cloud-init (`infra/k3s.tf`) formats it + bind-mounts onto `…/agent/containerd` and `…/k3s/storage` **before** k3s. Reason: 50GB EBS root is too small for vLLM image (~9GB compressed / ~27GB unpacked) + 7.6GB weights → DiskPressure eviction loop. Keep EBS root for OS only.
- **`user_data_replace_on_change = true`** in `infra/compute.tf`. WITHOUT it, editing `user_data` only stop/starts the box (new IP, cloud-init does NOT re-run, instance-store wiped) — changes silently never apply. With it, a user_data edit forces a full instance replacement so cloud-init re-runs clean. (To force a rebuild when user_data is unchanged in state: `terraform apply -replace=aws_instance.k3s`.)
- **vLLM** (`apps/aws-gpu/vllm/`): `vllm/vllm-openai:v0.22.0`, `--model microsoft/Phi-3-mini-4k-instruct`, `--served-model-name phi-3-mini`, `HF_HOME=/models` on a `local-path` PVC (NVMe-backed). Weights pull direct from HF on first boot (no S3, no AWS creds in pod). `runtimeClassName: nvidia` + `nvidia.com/gpu:1`. **NodePort 30800** (Service) + matching SG ingress in `infra/network.tf` (scoped to `local.my_cidr`). Test: `curl http://<public_ip>:30800/v1/chat/completions …`.
- **Single GPU = one exclusive workload.** `nvidia.com/gpu:1` is held for a pod's whole life; the old gpu-smoke-test Job starved (DeadlineExceeded) once vLLM held the GPU → **smoke test removed**. vLLM readiness (apps `wait:true`) is the GPU health gate. Co-scheduling 2 GPU pods needs operator time-slicing.

---

## 5. Repo layout (fleet-infra) — current

```
.sops.yaml                              # age recipient + encrypt rules (data/stringData, *.secret.yaml)
clusters/
├── hardway/{flux-system/, infrastructure.yaml, apps.yaml(+sops decryption)}
└── aws-gpu/{infrastructure.yaml, apps.yaml}   # flux-system/ re-created by flux-bootstrap on rebuild
infrastructure/
├── sources/base/{runai-oci.yaml, nvidia-helm.yaml(NGC HelmRepository)}
└── controllers/{base/{coredns,fake-gpu-operator,nvidia-gpu-operator}, hardway/, aws-gpu/}
       aws-gpu/nvidia-gpu-operator-values.yaml  # driver+toolkit disabled
apps/
├── base/gpu-demo/
├── hardway/{kustomization.yaml, demo.secret.yaml(SOPS)}   # gpu-demo x4 + encrypted secret
└── aws-gpu/{namespace.yaml, kustomization.yaml, vllm/{pvc,deployment,service}.yaml}
```
(`apps/aws-gpu/gpu-smoke-test.yaml` was removed — see §4.)

---

## 6. Decisions locked
- IaC = **Terraform** (Baseten uses it). State = S3 native locking, no DynamoDB. Two-stack split (infra/flux-bootstrap) via `terraform_remote_state`.
- Flux bootstrap = SSH-only writeable deploy key; PAT consumed once by the github provider (creates the key, never touches the cluster). Per-cluster keys are cleaned by `terraform destroy`.
- Region us-west-2. aws-gpu **on-demand** (spot capacity unavailable; `instance_market_options` commented in compute.tf).
- GPU on k3s = **host driver+toolkit, operator device-plugin-only**. NVIDIA chart from **HelmRepository** (NGC, public); nvcr.io OCI charts 403 without a token. Operator pinned v26.3.2.
- Images+cache on **instance-store NVMe**; `user_data_replace_on_change=true` (§4).
- Inference = **vLLM v0.22.0 / Phi-3-mini-4k**, direct-from-HF to local-path PVC, NodePort 30800.
- Secrets = **SOPS + age** (NOT KMS — cloud-agnostic, multi-recipient for fleets). `encrypted_regex: ^(data|stringData)$`.

---

## 7. Rebuild Track B (the known clean dance)

```bash
# 0. sync git (flux-bootstrap destroy removed clusters/aws-gpu/flux-system; it's re-added on apply)
cd /Users/dbilleci/Development/slikk66/fleet-infra && git pull --ff-only origin main

# 1. infra (new cloud-init: NVMe + DKMS driver + k3s; first boot ~6-8 min)
cd /Users/dbilleci/Development/slikk66/flux-gpu-trainer/iac/aws-gpu/infra
AWS_PROFILE=billeci terraform apply -auto-approve

# 2. flux-bootstrap (re-creates deploy key + flux, re-commits clusters/aws-gpu/flux-system)
cd ../flux-bootstrap && AWS_PROFILE=billeci terraform apply -auto-approve

# 3. pull the re-added gotk files
cd /Users/dbilleci/Development/slikk66/fleet-infra && git pull --ff-only origin main
```
Verify (KUBECONFIG = infra `.local/kubeconfig`): node Ready & STAYS Ready · `nvidia` RuntimeClass · `nvidia.com/gpu`=1 · `kubectl get ds -n gpu-operator | grep -E 'driver|toolkit'` EMPTY · `flux get kustomizations` all READY · `curl http://$(terraform -chdir=…/infra output -raw public_ip):30800/v1/models`.
**Teardown:** `terraform destroy` flux-bootstrap FIRST (cluster alive → clean), then infra. Confirm $0/hr.

---

## 8. Forward agenda (Baseten prep — main arc is done)

Prep exercises, best on **hardway** (free). Prioritized for the cloud-platform role:
- **SOPS depth:** multi-recipient (2nd age key → `sops updatekeys` → either key decrypts = fleet pattern); rotation; External Secrets Operator for the key-injection bootstrap.
- **GPU time-slicing + PriorityClass/preemption:** advertise the (fake) GPU as N replicas, co-schedule 2 pods, force a preemption. (User now understands PriorityClass→admission→`spec.priority`→scheduler/preemption.)
- **Terraform module refactor:** turn `iac/aws-gpu` into a reusable module + 2nd instantiation + plan-in-CI (GitHub Action).
- **Observability:** dcgm-exporter → Prometheus → Grafana.
- **AWS (read/lab, not necessarily on hardway):** Karpenter (GPU NodePools), EKS Pod Identity/IRSA (the correct answer vs the IMDS-node-role smell), AWS LB Controller. EKS Workshop has hands-on modules.
- **Fleet/MCM concepts:** Cluster API, multi-cluster GitOps placement, Flux fleet repo structure.
- **Read before day one:** Baseten's Truss (model packaging), cold-start blog posts, Baseten Chains.

---

## 9. Gotchas / risks
- **Cost:** aws-gpu ~$1.21/hr on-demand. `destroy` BOTH stacks (flux-bootstrap first) when done. Currently $0.
- **user_data stop/start trap (§4):** never assume a `user_data` edit rebuilt the box — confirm a NEW `instance_id` after apply, else it just stop/started (cloud-init didn't run, instance store wiped, IP changed but cert SAN stale).
- **Instance store is ephemeral:** wiped on stop/terminate; a reboot drops the bind-mounts → k3s would re-pull images. We create/destroy (never stop/start), so fine. DKMS driver rebuild ~3-4 min at first boot.
- **New public IP every rebuild** (no EIP). NodePort 30800 + SG are stable in code; re-read IP from `terraform output public_ip`.
- **vLLM endpoint is unauthenticated** — SG-scoped to `local.my_cidr` only; never widen to 0.0.0.0/0.
- **local-path PVC is node-local + ephemeral on the NVMe** — model cache lost on node replacement (re-downloads from HF). Fine for this lifecycle.
- **age private key:** 3 copies (Mac master, hardway Secret). Back up the master; never commit it. Lose all → encrypted secrets unrecoverable.
- **hardway 3 cluster-fixes not in git** (§3); spot capacity for g5.xlarge was unavailable in us-west-2a (on-demand fallback).

---

## 10. User preferences
Extremely concise, sacrifice grammar. **NEVER use the AskUserQuestion picker** — plain text questions, bullets OK. End plans with concise unresolved-questions list. TypeScript/node22/yarn; GitHub via gh CLI. Commit trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Teaching welcome but tight; user asks sharp follow-ups and wants the "why."
