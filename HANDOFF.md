# HANDOFF — flux-gpu-trainer / fleet-infra

> Cold-start pickup doc. What's needed to resume, not a history log.
> Companion: `docs/CHEATSHEET.md` (concepts + commands, through session 5). Update both when state changes.

---

## ▶ NEXT SESSION COLD-START — START HERE (updated session 8, 2026-06-04)

**Active work:** Flux **multi-tenancy** build on **hardway** (free). IN PROGRESS as of session 8 — see "Tenancy build status" below.

**✅ TCC IS FIXED (session 8): the macOS UPDATE cleared the Local Network gate. The direct path works first-try — the SSH tunnel is RETIRED. Just connect directly:**
```bash
export KUBECONFIG=/Users/dbilleci/Development/slikk66/flux-gpu-trainer/k8s-hardway/admin.kubeconfig
kubectl get nodes        # both Ready — confirmed session 8 (Go bins reach VM IPs again, no tunnel)
flux get kustomizations  # expect all READY
```
If OrbStack was just (re)started, wait ~30-60s for the host↔VM L3 path to settle, then retry. The old loopback-SSH-tunnel workaround (`admin-tunnel.kubeconfig`) is no longer needed — kept only as a fallback note in §9 in case TCC ever regresses on a future macOS point release.

**Post-restart cleanup that may be needed after any OrbStack/Mac restart** (stale pods from the kubelet/GPU-plugin outage, all benign — `UnexpectedAdmissionError` from the device-plugin not being Ready at admission time):
```bash
# force-delete any stuck Unknown/Terminating pods so controllers reschedule fresh
kubectl get pods -A --no-headers | grep -E "Unknown|Terminating" | \
  while read ns n _; do kubectl delete pod -n "$ns" "$n" --force --grace-period=0; done
```
Then wait ~60-90s: cilium `node.cilium.io/agent-not-ready:NoSchedule` taint auto-clears when each worker's cilium agent goes Ready, which unblocks `gpu-demo` (x4) scheduling. Healthy end state: 2 nodes Ready · all pods Running · flux all READY · GPUs 2+2 · gpu-demo x4 bin-packed 2/node · secret `gpu-apps/demo-credentials` present.

**Plan (direction agreed session 6; confirm open Qs before building):** "go deep on Flux tenancy first, then the rest incrementally." Two tenants `team-a` / `team-b`. Use the **real platform-team pattern** (= what the Baseten cloud-platform role actually does): the platform repo (`fleet-infra`) holds the *guardrails*; each tenant gets their *own* repo for workloads. Baseten nuance: their paying customers don't self-serve GitOps — the control plane/MCM provisions per-tenant ns+quota+placement — but the guardrail layer we build (ns + SA + RBAC + quota + netpol + Flux impersonation) is identical and is the transferable core.

Phases:
1. **Flux tenant isolation (DEEP — do this first):**
   - **Controller lockdown** — patch `clusters/hardway/flux-system/kustomization.yaml` to add to the kustomize-controller + helm-controller `args`: `--no-cross-namespace-refs=true`, `--no-remote-bases=true`, `--default-service-account=default`. (Verified session 6: NOT set today — controllers only have `--watch-all-namespaces=true`, and that kustomization.yaml has no `patches:`.)
   - **Per-tenant guardrails** in fleet-infra (e.g. `tenants/hardway/team-a/`): `Namespace`, `ServiceAccount`, `RoleBinding` (admin scoped to that ns only), + the tenant's Flux `GitRepository` + `Kustomization` with `spec.serviceAccountName: <tenant-sa>` (impersonation) and `spec.targetNamespace`.
   - **Tenant workload repo:** a separate GitHub repo per tenant (read-only deploy key for its `GitRepository`).
   - **Teaching payoff:** a tenant manifest that tries to touch another ns / cluster-scoped object → Flux apply DENIED under impersonation. Demonstrate the boundary explicitly.
2. **Resource quota:** `ResourceQuota` (cap `nvidia.com/gpu`, cpu, mem) + `LimitRange` per tenant ns.
3. **GPU time-slicing:** fake-gpu-operator advertise N GPU replicas; co-schedule team-a + team-b GPU pods.
4. **Scheduling fairness:** `PriorityClass` per tenant + force a preemption.
5. **Network isolation:** default-deny `NetworkPolicy` per ns + `CiliumNetworkPolicy` cross-tenant deny (Cilium is hardway's CNI).

**DECIDED session 7:** **separate real GitHub repos per tenant** (user OK'd the faithful pattern after the two-layer explanation: fleet-infra = guardrails layer; each tenant's own repo = workload layer, pulled via read-only deploy key). Plan: create `slikk66/tenant-team-a` + `slikk66/tenant-team-b` via `gh`, each with a `deploy/` dir of 2-3 tiny manifests (boundary lesson is identical at any repo size). Baseten caveat still holds: their customers don't self-serve git — MCM provisions tenants — but the guardrail layer is the transferable core; separate repos are the canonical way to *learn* the impersonation + deploy-key + boundary mechanics.

**DECIDED session 8 (defaults confirmed by user):** tenant names `team-a` / `team-b`; fleet-infra guardrail layout `tenants/hardway/<tenant>/`; order = **in-repo guardrails first**, create the GitHub tenant repos as needed.

### Tenancy build status (session 8 — UPDATE AS YOU GO)
- [x] Phase-1a **Per-tenant guardrails** — `tenants/hardway/{team-a,team-b}/` (ns + SA + ns-scoped admin RoleBinding), wired via `clusters/hardway/tenants.yaml`. Applied + verified (commit `23dd8c4`). `kubectl auth can-i --as` confirms team-a SA = admin in team-a, denied elsewhere/cluster-scoped.
- [x] Phase-1b **Controller lockdown** (commit `953b111`) — patches in `clusters/hardway/flux-system/kustomization.yaml`: `--no-cross-namespace-refs` (kustomize/helm/notification), `--no-remote-bases` (kustomize), `--default-service-account=default` (kustomize/helm), + pin root `flux-system` Kustomization to `serviceAccountName: kustomize-controller`. Platform Kustomizations infrastructure/apps/tenants pinned inline to same SA. **The lockdown surfaced 2 real issues, both fixed:**
  - **Cross-ns source refs** (commit `acc4c57`): HelmReleases in `gpu-operator` referenced sources in `flux-system`. Fix = co-locate each source in its operator base, in `gpu-operator` ns; deleted shared `infrastructure/sources/base` catalog + its overlay refs.
  - **Unprivileged Helm impersonation** (commits `045ee06`+`cdd7a01`): `--default-service-account` governs helm-controller too → HR without `serviceAccountName` runs as powerless `gpu-operator:default`. Fix = `ServiceAccount gpu-operator/helm-installer` + ClusterRoleBinding→cluster-admin (trusted PLATFORM installer) in each operator base; HR `spec.serviceAccountName: helm-installer`. (Gotcha hit: forgot to add rbac.yaml to fake base's kustomization.yaml first → HR impersonated a non-existent SA = same zero perms.)
  - End state: all 4 Kustomizations + HR READY @ `cdd7a01`, cluster fully healthy.
- [x] Phase-1c **Tenant workload repos** (commit `157e09f`) — `slikk66/tenant-team-a` / `-team-b` (private, each `deploy/` = whoami Deployment + ConfigMap, read-only deploy keys `flux-hardway-ro`). Per-tenant `deploy-key.secret.yaml` (SOPS, in tenant ns) + `sync.yaml` (`GitRepository` ssh + `Kustomization` `serviceAccountName: <t>` + `targetNamespace: <t>`). Added `decryption:` to `clusters/hardway/tenants.yaml`. Verified: both GitRepositories clone via deploy key, both tenant Kustomizations READY, `team-{a,b}-whoami` Running in their ns. (Gotcha: decryption config + encrypted secret in same commit → first reconcile pass failed "SOPS encrypted, configuring decryption required", self-corrected on next pass once root applied the new tenants spec.)
- [x] Phase-1d **Boundary-denial demo** — pushed a cluster-scoped `ClusterRole` to tenant-team-a's `deploy/`; team-a Kustomization went NotReady: `clusterroles ... forbidden: User "system:serviceaccount:team-a:team-a" cannot patch ... at the cluster scope` (denied at dry-run, atomic). ClusterRole never created; team-a-whoami stayed Running; team-b unaffected. Reverted → team-a green again. **Boundary proven.**
- **Docs:** `docs/tenancy-architecture.md` (mermaid) + `docs/tenancy-architecture.html` (browser-renderable; no VS Code ext needed). Note for viewing mermaid in VS Code: needs Workspace Trust + `bierner.markdown-mermaid` + window reload.
- [x] Phase-5 **NetworkPolicy isolation** (commit `ab1cebd`, done OUT OF ORDER by user request) — `tenants/hardway/<t>/networkpolicy.yaml`: one standard `networking.k8s.io` NetworkPolicy per tenant ns (`podSelector {}` + ingress from same-ns only = default-deny + intra-tenant allow), platform-owned, enforced by Cilium. **Demoed:** before = `team-a→team-b` HTTP 200; after = cross-tenant `curl (28) timed out` (silent drop, not refused), same-ns `team-b→team-b` still 200. Clarified: Cilium enforces standard NetworkPolicy (sufficient); `CiliumNetworkPolicy` is a superset CRD only needed for L7/FQDN/cluster-wide. Egress left open (DNS intact). Probes via ephemeral `curlimages/curl` pods (whoami is scratch, no shell).
- [x] **MIG familiarization** (session 8, fake mig-faker) — partitioned worker-2's GPU into a mixed geometry; team-a + team-b each hold a slice on the SAME node (spatial multi-tenancy). **GitOps state (committed, persists):** `infrastructure/controllers/hardway/fake-gpu-operator-values.yaml` adds a `mig` nodePool (gpuCount:1 + `otherDevices`: 1×`nvidia.com/mig-3g.40gb`, 2×`nvidia.com/mig-1g.10gb`); `gpu-nodes.yaml` puts worker-2 in pool `mig`; `apps/hardway/kustomization.yaml` gpu-demo temporarily at **2** (RESTORE to 4 when done). **Result:** worker-2 advertises gpu=1 + mig-3g.40gb=1 + mig-1g.10gb=2; demo pods `team-a/mig-job` (3g.40gb) + `team-b/mig-job` (1g.10gb) Running on worker-2.
  - **Mechanism learned:** device-plugin registers `otherDevices.name` VERBATIM as a schedulable extended resource. Per-node scoping via a separate nodePool + `run.ai/simulated-gpu-node-pool` label (GitOps in gpu-nodes.yaml). mig-faker (node label `node-role.kubernetes.io/runai-dynamic-mig=true` + annotation `run.ai/mig.config` = mig-parted-style YAML) fakes the GFD mapping/labels but does NOT advertise schedulable resources — that's `otherDevices`.
  - **⚠ SMELL / caveat (imperative, NOT GitOps):** the fake operator is built for STATIC topology. status-updater creates per-node `topology-<node>` CM **once on node-add** (never rewrites on pool change); device-plugin reads topology **once at startup**. So applying a MIG change to a running node required: delete stale `topology-worker-2` CM → `kubectl rollout restart deploy/status-updater` (rebuilds it from the mig pool) → restart worker-2's `device-plugin` pod. On a fresh operator/cluster start it self-heals from git (worker-2 already labeled mig). The mig-faker node label+annotation + the `mig-job` demo pods are imperative (not in git).
  - **KEPT (user decision, session 8):** MIG setup stays — worker-2 in the `mig` pool, gpu-demo at 2 (only 3 whole GPUs cluster-wide now). The `mig-job` demo pods Completed (slices freed; setup intact). Available for phase 3 (time-slicing) to build on.
- [x] **Phase-2 ResourceQuota + LimitRange** (session 8) — `tenants/hardway/<t>/quota.yaml` (platform-owned). The THIRD boundary (consumption). team-a larger (req 2cpu/2Gi, 1 whole gpu, 1× mig-3g.40gb) vs team-b smaller (1cpu/1Gi, 2× mig-1g.10gb). LimitRange = required companion (default 100m/128Mi req, 250m/256Mi lim; min 10m/16Mi, max per-container). **Demoed:** bare pod → LimitRange injects defaults; over-quota pod → `Forbidden: exceeded quota` at admission. GPU/MIG resources quota-able via `requests.<resource>`.
- **➡ NEXT:** Phase 3 (GPU time-slicing co-schedule — can build on the kept MIG setup) + phase 4 (PriorityClass/preemption). Runtime isolation (PSA/seccomp) = deprioritized per user (do last, maybe skip). All on hardway (free).
- **Optional bonus not yet done:** a `CiliumNetworkPolicy` L7 demo (e.g. allow `GET /` deny `POST`) to show the superset; offered, user may want later.
- **Tenant deploy keys:** private halves at `flux-gpu-trainer/tenant-repos/.keys/{team-a,team-b}` (local-only, mode 600). Public halves registered read-only on each repo. In-cluster as SOPS-decrypted `Secret <ns>/deploy-key`.

**Cluster changes NOT in git — VM-local** (session 7): `failSwapOn: false` on both workers' kubelet-config (see §3, cluster-fix #4). Re-apply if VMs rebuilt.

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
- **GitOps repo (pushed):** `/Users/dbilleci/Development/slikk66/fleet-infra/` → `git@github.com:slikk66/fleet-infra` (branch `main`). **HEAD = `ef8b8a0`** (handoff edit pending commit otherwise clean).

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
- **5 cluster-fixes NOT in git** (re-apply if cluster rebuilt): (1) ClusterRole `system:kube-apiserver-to-kubelet` + binding; (2) apiserver `--advertise-address=192.168.139.92` (edit `/etc/systemd/system/kube-apiserver.service` on control-1, `.bak` exists); (3) CoreDNS bootstrap seed (now in git, Flux adopted); (4) **`failSwapOn: false`** appended to `/var/lib/kubelet/kubelet-config.yaml` on **both workers** (session 7). OrbStack re-enables swap (`zram0`+`vdc`) on every VM restart; without this, kubelet exits `1/FAILURE` ("running with swap on is not supported") and the node never goes Ready. Per-worker file (different cert paths) — edit each, then `sudo systemctl restart kubelet`. (5) **API aggregation layer** (session 8) — front-proxy CA + proxy-client cert + 8 requestheader/proxy-client/`enable-aggregator-routing` flags on the apiserver, needed for aggregated APIs (metrics.k8s.io). Captured + reproducible: **`scripts/hardway/05-enable-aggregation-layer.sh`** (run on control-1: `ssh control-1@orb 'sudo bash -s' < scripts/hardway/05-enable-aggregation-layer.sh`). Front-proxy PKI masters live in the workbench `k8s-hardway/front-proxy-*.pem` alongside the rest; VM copies in `/var/lib/kubernetes/`.
- **SOPS+age (live):** `apps/hardway/demo.secret.yaml` is SOPS-encrypted; hardway `apps` Kustomization has `decryption: {provider: sops, secretRef: sops-age}`; Flux decrypts → `Secret gpu-apps/demo-credentials` (cleartext) in-cluster. To edit: `sops apps/hardway/demo.secret.yaml`. To view: `SOPS_AGE_KEY_FILE=…/.sops/age.agekey sops -d apps/hardway/demo.secret.yaml`.
- **metrics-server (live, session 8):** `infrastructure/controllers/base/metrics-server` (HelmRepository + cluster-admin installer SA + HelmRelease chart 3.13.0), hardway overlay only (k3s/aws-gpu has its own). Serves `metrics.k8s.io` → `kubectl top nodes/pods` + HPA. Needs cluster-fix #5. Runs **hostNetwork on :4443** (see §9 — apiserver can't reach pod IPs).

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
- **apiserver (control-1) CANNOT reach pod IPs (session 8):** control-1 is "apiserver, not a node" — it has routes to node IPs (`192.168.139.0/24`) but NONE to the Cilium pod CIDR (`10.200.0.0/16`). So any **aggregated APIService or admission webhook** whose endpoint is a *pod* IP fails the apiserver's reachability/discovery probe (saw `APIService FailedDiscoveryCheck`; `ssh control-1@orb curl pod-IP:port` → timeout, node-IP → connects). **Fix pattern: run such components `hostNetwork: true`** so the endpoint is the node IP (reachable) — metrics-server does this on `:4443` (10250 = kubelet). Future webhooks (cert-manager, etc.) will need the same, or a host route on control-1 to a node's pod subnet.
- **A broken aggregated APIService destabilizes the whole control plane (session 8):** while metrics-server's `metrics.k8s.io` APIService was `FailedDiscoveryCheck`, the apiserver's **aggregated discovery** blocked on the dead endpoint's timeout on every discovery call → apiserver intermittently slow for ALL clients → flux **kustomize-controller crash-looped** on `leader election lost` (lease PUTs to `10.32.0.1:443` timing out) while direct apiserver access stayed fast. Symptom: multiple Kustomizations stuck `Reconciliation in progress`, controller RESTARTS climbing. **Fix:** repair/remove the bad APIService, then `kubectl rollout restart deploy/kustomize-controller -n flux-system`. Lesson: don't leave a half-working APIService registered.
- **macOS Local Network TCC gate (sessions 6-7) — ✅ FIXED session 8 by the macOS update.** History: on macOS **26.5**, Go CLIs (`kubectl`, `flux` at `/opt/homebrew/bin`) got `connect: no route to host` to OrbStack VM IPs (`192.168.139.92:6443`) while Apple `/usr/bin` binaries (`curl`/`nc`/`ping`) worked (exempt); the documented per-app toggle fix never cleared it. The macOS point-update applied before session 8 resolved it — Go bins now reach VM IPs directly, tunnel retired. **Fallback if it ever regresses:** loopback SSH tunnel `ssh -f -N -L 127.0.0.1:6443:localhost:6443 control-1@orb` (Apple ssh + OrbStack = TCC-exempt) + a kubeconfig with `server: https://127.0.0.1:6443` (in cert SAN); `admin-tunnel.kubeconfig` still on disk. **Diagnose test:** `/usr/bin/curl -sk https://192.168.139.92:6443/healthz` → `ok` while `kubectl` says `no route to host` = TCC gate, not the cluster. Note: right after an OrbStack restart the host↔VM L3 path takes ~30–60s to settle — wait and retry.
- **OrbStack VM restart re-enables swap → kubelet crash-loop (NEW session 7):** any stop/start of the OrbStack VMs (or a Mac restart) brings swap back (`/dev/zram0`+`/dev/vdc`, not in fstab — OrbStack/guest-agent enables it). Default kubelet refuses swap → both workers crash-loop `1/FAILURE`, NotReady, and CoreDNS/cilium-operator wedge Pending. Permanently mitigated by cluster-fix #4 (`failSwapOn: false`, §3) — kubelet now starts regardless. If a future rebuild loses that, the symptom in `journalctl -u kubelet` is "running with swap on is not supported".
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
