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
| `flux-gpu-trainer` | local only | workbench: hard-way PKI/scripts, Terraform IaC, notes | never |
| `fleet-infra` | github.com/slikk66 (private) | GitOps source of truth | yes |

`fleet-infra` layout (Flux monorepo): `clusters/<name>/` (entrypoints) · `infrastructure/controllers/{base,<cluster>}` · `apps/{base,<cluster>}`. Track B's Terraform lives in the **workbench** repo's `iac/aws-gpu/` (not in fleet-infra).
Reconcile order per cluster: **infrastructure before apps**.

## Clusters

- **hardway** — "Kubernetes the hard way" on OrbStack Ubuntu arm64 VMs (control-1 + worker-1/2). Cilium CNI w/ kube-proxy replacement. ≈ the "bare-metal / colo" experience.
- **aws-gpu** — g5.xlarge (A10G), us-west-2, k3s 1.33, real NVIDIA GPU Operator (device-plugin-only; driver+toolkit host-managed — see Session 4). Terraform-provisioned. **On-demand** (~$1.21/hr; spot capacity unavailable). ≈ the "managed cloud" experience. Both reconcile from `fleet-infra`.

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

### 4. DNS bootstrap chicken-and-egg (RESOLVED)
- Flux reached the API but source-controller couldn't resolve `github.com`:
  `lookup github.com on 10.32.0.10:53: i/o timeout` — **no CoreDNS in the cluster**.
- CoreDNS was intended via GitOps, but Flux needs DNS to clone the repo that *contains* CoreDNS.
- **Resolution:** seeded CoreDNS once (`kubectl apply` of the same manifest now in
  `infrastructure/controllers/base/coredns`), then committed it to git. Flux **adopted** the
  existing objects (server-side apply, no diff) and now owns them — proven by the label
  `kustomize.toolkit.fluxcd.io/name: infrastructure` on the coredns Deployment.
- Pattern: every cluster needs a minimal **bootstrap seed**; GitOps takes over immediately after.

---

## Flux in depth (reference)

### Components (the GitOps Toolkit / "gotk")
Each controller watches one CRD and does one job:
| Controller | Watches (CRD) | Job |
|------------|---------------|-----|
| source-controller | GitRepository, OCIRepository, HelmRepository, Bucket | fetch + verify, produce an internal **artifact** (tarball at a revision/sha) |
| kustomize-controller | **Kustomization** (`kustomize.toolkit.fluxcd.io`) | build kustomize from an artifact path, **server-side apply**, prune, health-check |
| helm-controller | HelmRelease | render + install/upgrade Helm charts |
| notification-controller | Alert, Provider, Receiver | outbound alerts + inbound webhooks |

### Two different "Kustomization" (key gotcha)
- `kustomization.yaml`, kind `Kustomization`, group **kustomize.config.k8s.io** = plain Kustomize build file (just lists resources/patches). Inert.
- Flux `Kustomization`, group **kustomize.toolkit.fluxcd.io** = a reconciler **object**: "from `sourceRef`, build `path`, apply with `prune`/`wait`/`interval`, ordered by `dependsOn`." This is the active piece.

### What `flux bootstrap github` did (maps to its output)
1. Cloned the repo (token, once).
2. Generated **gotk-components.yaml** (all CRDs + controller Deployments + RBAC) → committed/pushed to `clusters/hardway/flux-system/`.
3. Installed those components into the cluster.
4. **Source secret**: created an SSH **deploy key**, registered the *public* key on the GitHub repo, stored the *private* key as Secret `flux-system/flux-system`.
5. Generated **gotk-sync.yaml** = a GitRepository + a Kustomization (both named `flux-system`) → committed/pushed.
6. Applied sync manifests → Flux now reconciles **itself** from git (components live in the repo; upgrades = bump version, commit).

### Reconciliation loop
git commit → source-controller pulls on `interval` → new artifact (sha) →
kustomize-controller builds + server-side applies + prunes + health-checks → status in `flux get`.
**Drift correction:** hand-edit a managed object and next reconcile reverts it to git. Git is truth.

### Ordering & safety knobs (on the Flux Kustomization)
- `prune: true` — delete-from-git ⇒ delete-from-cluster.
- `wait: true` — block until applied resources are Ready (health-gates dependents).
- `dependsOn:` — ordering. **apps dependsOn infrastructure** ⇒ GPU operator exists before GPU workloads.

### Credentials
Durable pull cred = **read-only SSH deploy key**, scoped to ONE repo (least privilege). The GitHub token is only used during bootstrap. Prod (Baseten-shaped) drives bootstrap from IaC with a GitHub App / machine-user PAT — same end-state deploy key.

### Everyday commands
```bash
flux get sources git                          # is the repo fetched? at what sha?
flux get kustomizations                        # which paths are applied + Ready?
flux reconcile source git flux-system          # force a pull now
flux reconcile kustomization <name> --with-source   # force pull + apply
flux check / flux check --pre                  # controller + CRD health / preflight
flux tree kustomization <name>                 # what objects a Kustomization manages
```

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

---

## Session 2 — GPU Operator + apps layer

### OCIRepository + HelmRelease (the modern chart pipeline)

```yaml
# infrastructure/sources/base/runai-oci.yaml — the source
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata: { name: fake-gpu-operator, namespace: flux-system }
spec:
  interval: 30m
  url: oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator   # WITHOUT tag
  ref: { tag: "0.0.81" }                                          # tag/semver/digest

# infrastructure/controllers/base/gpu-operator/helmrelease.yaml — the consumer
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: fake-gpu-operator, namespace: gpu-operator }
spec:
  interval: 15m
  chartRef:                          # MODERN form: direct source ref, no catalog lookup
    kind: OCIRepository
    name: fake-gpu-operator
    namespace: flux-system           # cross-ns sourceRef is fully supported
  install: { remediation: { retries: 3 } }
  upgrade: { remediation: { retries: 3, remediateLastFailure: true } }
  valuesFrom:
    - kind: ConfigMap
      name: gpu-operator-values      # same name in EVERY cluster overlay, different content
```

Two reconcile loops compose: source-controller pulls the OCI artifact → exposes it at `http://source-controller.flux-system.svc/...` → helm-controller fetches that tarball → renders chart with merged values → calls `helm install`. They communicate only via the source's `.status.artifact`. Inspect with:

```bash
flux get sources oci -A
flux get helmreleases -A
helm list -A                                  # the underlying Helm releases
kubectl -n flux-system get ocirepository <name> -o yaml | yq '.status.artifact'
```

### OCI vs HelmRepository (classic)

| OCIRepository | HelmRepository (classic) |
|---|---|
| `oci://ghcr.io/...` (Docker Hub, ECR, GAR, etc.) | `https://example.com/index.yaml` |
| `chartRef:` on HR (direct) | `chart.spec.{chart,version,sourceRef}` on HR (catalog lookup) |
| Cosign-signable, digest-immutable | No standardized signing |
| One auth/mirror surface (image registry) | Separate HTTP-hosted catalog |
| Modern default (Baseten-shape) | Legacy / lots of older charts still live here |

### The SSA-patch + prune-disabled pattern (for pre-existing/co-owned resources)

When Flux SSA-patches a resource it didn't create (Node, kube-system ns, default SA, vendor CRD), the resource enters Flux's inventory. `git rm` → next reconcile prune-deletes it. For Nodes: pod eviction storm.

```yaml
metadata:
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled   # Flux manages updates, never deletes
```

Pulumi analogue: `pulumi import` + `pulumi destroy` destroys the imported resource. Fix is `protect: true`. Same shape, same trap.

**Apply this annotation on:** Nodes, kube-system ns, default ns, default SAs, any CRD that an operator co-manages.

### SSA field ownership

Each resource's `.metadata.managedFields[]` is an array, one entry per manager (`kubelet`, `kustomize-controller`, `cilium-operator-generic`, ...). Tracks per-field ownership using `f:` notation.

```bash
kubectl get node worker-1 --show-managed-fields -o yaml | yq '.metadata.managedFields[] | {"manager": .manager, "op": .operation}'
kubectl get node worker-1 --show-managed-fields -o yaml | yq '.metadata.managedFields[] | select(.manager == "kustomize-controller") | .fieldsV1'
```

- **`Apply`** op = server-side apply (Flux + modern tooling) — declares ownership of fields.
- **`Update`** op = imperative PUT/PATCH (legacy controllers) — also recorded as ownership.
- **Maps tracked per-key** (labels, annotations): different managers can coexist on different keys.
- **Some lists atomic** (whoever sets owns the whole list): containers' `args`, env vars in some setups.
- **Conflict** = two managers want the same field → SSA refuses unless `force: true`. Flux: `kustomize.toolkit.fluxcd.io/force` annotation.

### Cross-Kustomization ordering

```yaml
# clusters/hardway/apps.yaml — Flux Kustomization with dependsOn
spec:
  dependsOn:
    - name: infrastructure         # apps won't START reconciling until this is Ready
  wait: true                        # apps itself blocks until its resources are Ready
```

Combined with `wait: true` on the depended-on Kustomization, **Ready means "all resources health-pass"** (Deployments rolled, HRs `Released`, etc.). So `apps` literally cannot reconcile until the GPU operator's DaemonSets are running and advertising capacity. Bootstrap a fresh cluster → workloads automatically land in the right order.

### Composition vs Overlay (kustomize)

| | Composition | Overlay |
|---|---|---|
| `kustomization.yaml` | `resources:` only | `resources:` + transformer(s) |
| Modifies base resources? | No (passes through) | Yes |
| Example transformers | (none) | `patches:`, `replicas:`, `images:`, `namespace:`, `namePrefix:`, `commonLabels:`, `commonAnnotations:`, `configMapGenerator:`, `secretGenerator:` |

The convenience transformers (`replicas:`, `images:`, ...) are **sugar over `patches:`**. They produce identical rendered yaml as the equivalent JSON patch — kustomize gives them dedicated keys because they're so common.

Example overlay (our actual first one):
```yaml
# apps/hardway/kustomization.yaml
resources:
  - ../base/gpu-demo
replicas:
  - name: gpu-demo
    count: 4
```

### GPU scheduling end-to-end chain

```
pod yaml: resources.limits.nvidia.com/gpu: 1 + nodeSelector
   ↓
kube-scheduler: filters nodes by capacity + selectors, picks one
   ↓
kubelet on chosen node: calls device-plugin gRPC (Unix socket) "Allocate 1 GPU"
   ↓
device-plugin: returns UUID + env vars (MOCK_NVIDIA_VISIBLE_DEVICES=...)
   ↓
kubelet starts container with those env vars injected
   ↓
container sees the env, references the (fake or real) GPU
```

Real hardware vs fake: only the device-plugin's allocation logic differs. Every other step is identical.

### `flux diff` is the right preview tool

```bash
flux diff kustomization <name> --path ./path/in/repo
```

NOT `kubectl diff` from outside Flux — it false-positives on Flux's ownership-label transformer (`kustomize.toolkit.fluxcd.io/name`, `/namespace`) which stock kustomize doesn't replicate. Exits non-zero on any drift; wire into CI as a gate.

### Bonus: readiness gates (where applicable)

```yaml
spec:
  readinessGates:
    - conditionType: target-health.elbv2.k8s.aws/<arn>   # ALB Controller, or model-warmup, or ...
  containers: [...]
```

External controller votes INTO k8s pod readiness state. Pod is `Ready` only when readinessProbe AND every gate's condition is True. Used to prevent rolling-deploy 502s (Deployment waits to kill old pods until LB confirms new ones healthy). Baseten-relevant for model-warmup gates: don't route inference traffic until weights loaded + JIT warmed + warmup queries passed.

---

## State today (2026-06-01)

- 3 Flux Kustomizations on hardway: `flux-system`, `infrastructure`, `apps` — all Ready.
- 1 HelmRelease: `gpu-operator/fake-gpu-operator` @ 0.0.81.
- 4 fake H100s in cluster (2x NVIDIA-H100-80GB-HBM3 per worker).
- 4 gpu-demo pods bin-packed 2-per-worker, each holding a fake GPU UUID.
- MIG deferred to Track B (real silicon).

---

## Session 3 — Terraform (IaC for Track B / aws-gpu)

### Why Terraform (not Pulumi)
Baseten uses Terraform → decision locked. (Pulumi was the original workbench choice, dropped.)

### Native S3 state locking (no DynamoDB)
```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket       = "billeci-state-upgraded"
    key          = "terraform/aws-gpu/infra/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true     # native S3 lock (TF 1.11+). A .tflock object next to state. No DynamoDB.
    encrypt      = true
  }
}
```
Pre-1.11 required a DynamoDB table for the lock. `use_lockfile=true` is a conditional-write `.tflock` object in the same bucket. One less resource.

### Two-stack split + cross-stack refs
Separate state files: `iac/aws-gpu/infra/` (VPC/EC2/IAM/k3s) and `iac/aws-gpu/flux-bootstrap/` (deploy key + flux). **Why split:**
- `flux_bootstrap_git` and Flux itself both touch gotk-* resources. One combined stack → perpetual diff churn (TF keeps wanting to "fix" what Flux manages).
- Split = infra stays stable; flux-bootstrap is the only stack re-run on Flux changes.

flux-bootstrap reads infra outputs **read-only**:
```hcl
data "terraform_remote_state" "infra" {
  backend = "s3"
  config  = { bucket = "billeci-state-upgraded", key = "terraform/aws-gpu/infra/terraform.tfstate", region = "us-west-2" }
}
# use: data.terraform_remote_state.infra.outputs.kubeconfig_path
```
Convention: infra emits filesystem paths via `abspath()` so flux-bootstrap resolves them from a different working dir.

### Canonical Flux + Terraform bootstrap (SSH-only)
```hcl
resource "tls_private_key" "deploy" { algorithm = "ECDSA"; ecdsa_curve = "P256" }
resource "github_repository_deploy_key" "this" {
  repository = "fleet-infra"; title = "flux-aws-gpu"
  key       = tls_private_key.deploy.public_key_openssh
  read_only = false            # WRITEABLE — flux_bootstrap_git must COMMIT gotk files
}
resource "flux_bootstrap_git" "this" {
  path = "clusters/aws-gpu"; version = "v2.8.8"
  # flux provider configured with git { url = "ssh://...", ssh { private_key = tls_private_key.deploy... } }
}
```
- **PAT consumed once** by the `github` provider to register the deploy key. After that, *all* git auth is the SSH key. PAT never enters the cluster.
- Deploy key is **writeable** here (vs hardway's read-only) because `flux_bootstrap_git` *commits* the gotk manifests.
- PAT lives in `flux-bootstrap/terraform.tfvars` (gitignored, mode 600), fine-grained, one-repo scope (Contents R/W + Administration R/W).

---

## Session 4 — Real GPU on k3s (the hard lessons)

### NFD vs GFD vs nvidia-smi (who labels the node)
| Layer | What it does |
|---|---|
| **nvidia-smi** | host CLI → kernel driver. Ground truth: "is there a GPU + which driver". |
| **NFD** (Node Feature Discovery) | generic node labels (CPU/kernel/PCI). Detects NVIDIA PCI vendor → `feature.node.kubernetes.io/pci-10de.present=true`. |
| **GFD** (GPU Feature Discovery) | NVIDIA-specific labels: `nvidia.com/gpu.product`, `.count`, `.memory`, MIG geometry. |

Operator two-step: **discover → operator stamps `nvidia.com/gpu.deploy.*` labels → operands schedule.** NFD/GFD discover hardware; the operator reads those labels to decide which DaemonSets (driver/toolkit/device-plugin/dcgm/validator) to place.

**declare vs discover:** fake operator (hardway) → we **hand-label** nodes (`gpu-nodes.yaml` SSA-patch). Real operator (aws-gpu) → GFD **discovers** the A10G; no hand-labels, silicon is truth.

### ⚠️ THE BIG TRAP: GPU Operator toolkit breaks k3s 1.33
- k3s 1.33 ships **containerd 2.x** → CRI schema **`io.containerd.cri.v1`** (CRI v1).
- The operator's bundled **container-toolkit** (v1.19.1) rewrote containerd config in the **old `version=2` / `io.containerd.grpc.v1.cri`** schema AND replaced k3s's monolithic config, **dropping k3s's inline CNI `bin_dir`/`conf_dir`**.
- Result: CNI never initialized → **node NotReady, every pod `cni plugin not initialized`** (~3 min after operator install).

### The fix — Path A (host-managed driver + toolkit)
- **cloud-init installs the NVIDIA driver (`cuda-drivers` DKMS) + `nvidia-container-toolkit` BEFORE k3s.**
- k3s then **natively detects** `nvidia-container-runtime` and writes its OWN correct, CNI-safe containerd config — with `nvidia` + `nvidia-cdi` runtimes and a built-in `nvidia` RuntimeClass.
- GPU Operator runs **`driver.enabled=false` + `toolkit.enabled=false`** → only NFD/GFD/device-plugin/dcgm/validators. **No** `nvidia-driver-daemonset` / `nvidia-container-toolkit-daemonset`.
- Canonical k3s GPU recipe. Operator-everything is genuinely incompatible with this k3s/containerd combo.
- GPU pods set **`runtimeClassName: nvidia`** (selects the host runtime; without it the toolkit prestart hook never runs → no devices in the container).

Success signatures:
```bash
kubectl get runtimeclass                                          # nvidia present → k3s saw host toolkit
kubectl get node -o jsonpath='{...allocatable.nvidia\.com/gpu}'    # 1
kubectl get ds -n gpu-operator | grep -E 'driver|toolkit'         # EMPTY (host-managed)
```

### HelmRepository (NGC) vs OCIRepository (nvcr.io 403)
- nvcr.io's **OCI chart** registry now **403s without an NGC token** (component *images* still pull anonymously).
- So the GPU Operator chart comes from the classic **HelmRepository** `https://helm.ngc.nvidia.com/nvidia` (public):
```yaml
# HelmRelease, chart.spec form (HTTP catalog lookup) — NOT chartRef
spec:
  chart:
    spec:
      chart: gpu-operator
      version: v26.3.2
      sourceRef: { kind: HelmRepository, name: nvidia, namespace: flux-system }
```
Contrast the fake operator (session 2) using `chartRef:` → OCIRepository. **`chart.spec` = HTTP repo + catalog lookup; `chartRef` = direct OCI/Helm source ref.**

### Spot `InsufficientInstanceCapacity` silent-retry
g5.xlarge spot in us-west-2a was exhausted. Signature: `RunInstances` **loops silently** on `InsufficientInstanceCapacity` — no instance, no spot request, just Terraform "Still creating...". Fallback = comment out `instance_market_options` → on-demand (~$1.21/hr vs ~$0.63 spot that day).

### rtk caveat extends beyond git
The `rtk` hook truncates/mangles stdout for `git`, `helm`, `aws`, `kubectl`, `grep`, `wc`. Workarounds: `rtk proxy <cmd>` for raw output, call binaries by absolute path (`/usr/bin/grep`), or use the Read tool for files.

---

## Session 5 — Track B rebuilt + GitOps-native GPU proof (2026-06-03)

Rebuilt aws-gpu from scratch on the corrected Path A design. Came up clean:
- node Ready and **stayed** Ready (the old break took it NotReady ~3 min after operator install).
- `nvidia` RuntimeClass auto-created; `nvidia.com/gpu` allocatable = 1; **no** driver/toolkit daemonsets.
- host driver: **A10G, 610.43.02, CUDA UMD 13.3, 23 GB**.

### Pattern: smoke test as a Flux health-gate
Instead of imperative `kubectl run`, the smoke test is a **GitOps-managed Job** (`apps/aws-gpu/gpu-smoke-test.yaml`) running `nvidia-smi` with `nvidia.com/gpu:1` + `runtimeClassName: nvidia`. The parent `apps` Kustomization sets **`wait: true`**, so Flux health-checks the Job — and a Job is "Ready" only when it **Completes successfully**. Therefore:

> **`apps` Kustomization goes READY iff `nvidia-smi` exits 0 on the GPU.** The reconciliation *is* the proof, and it re-proves automatically on every rebuild — no out-of-band verification.

Same `dependsOn`+`wait` machinery from session 2, now used as a deliberate hardware-validation gate.

---

## Session 8 — Multi-tenancy + MIG (2026-06-05)

Full diagrams: **`docs/tenancy-architecture.md`** (or `.html`). This is the
concept/command reference.

### The model: two layers, three boundaries
- **Two layers.** *Platform* repo (`fleet-infra`, cluster-admin) draws the
  guardrails; each *tenant* gets its own repo and only fills the box. Guardrails
  live in `tenants/hardway/<tenant>/`, applied by a `tenants` Flux Kustomization
  (sibling of `infrastructure`/`apps`).
- **Three independent boundaries** around each tenant — different mechanisms,
  different enforcers, don't conflate:
  1. **Control plane** (RBAC + impersonation) — *what you can deploy*. apiserver, apply-time.
  2. **Data plane** (NetworkPolicy) — *what you can talk to*. Cilium, runtime.
  3. **Consumption** (ResourceQuota + LimitRange) — *how much you can use*. apiserver admission.

### Boundary ① — impersonation (the keystone)
- Flux's controllers are cluster-admin. **Impersonation** makes a Kustomization
  apply *as* a named SA, so the apiserver enforces that SA's RBAC.
- Controller **lockdown** (JSON6902 patches in `clusters/hardway/flux-system/kustomization.yaml`
  onto the gotk deployments):
  - `--default-service-account=default` (kustomize + helm) — a Kustomization/HelmRelease
    with no `serviceAccountName` impersonates the powerless `default` SA → **fails closed**.
  - `--no-cross-namespace-refs=true` (kustomize/helm/notification) — a ref (sourceRef,
    secretRef, chart source) may only point inside its own namespace.
  - `--no-remote-bases=true` (kustomize) — no remote kustomize bases.
- **The asymmetry:** platform Kustomizations set `serviceAccountName: kustomize-controller`
  (already cluster-admin); tenant Kustomizations set `serviceAccountName: <tenant>`.
  The default-SA flag also strands the platform's *own* Kustomizations unless pinned —
  so `infrastructure`/`apps`/`tenants` + the bootstrap `flux-system` are pinned to
  `kustomize-controller`. helm path is identical: platform HelmReleases name a
  cluster-admin installer SA (`gpu-operator/helm-installer`, `kube-system/helm-installer`).
- **RBAC scope = binding KIND, not SA namespace.** Tenant SA is `admin` via a
  **RoleBinding** (this namespace only). A `ClusterRoleBinding` to the same role
  would be cluster-wide. One SA can span N namespaces = N RoleBindings (subjects may
  reference a SA from another namespace). Cluster-scoped objects (ClusterRole,
  ClusterRoleBinding, Namespace) must have globally-unique names.
- **Tenant repo wiring** (`tenants/hardway/<t>/sync.yaml`): a `GitRepository` (ssh,
  `secretRef: deploy-key`) + a `Kustomization` with `serviceAccountName: <t>` and
  `targetNamespace: <t>`, both in the tenant ns. The read-only **deploy key** is a
  **SOPS-encrypted Secret** in the tenant ns (`deploy-key.secret.yaml`), decrypted by
  the platform `tenants` Kustomization (`decryption.secretRef: sops-age`). Tenant repos:
  `slikk66/tenant-team-{a,b}` (private; `deploy/` dir; `gh repo deploy-key add` read-only).
- **Boundary demo:** a tenant manifest creating a cluster-scoped ClusterRole →
  `Forbidden: ... cannot create clusterroles at the cluster scope` (dry-run, atomic).
- **Verify impersonation RBAC without Flux:**
  `kubectl auth can-i create deployments -n team-b --as=system:serviceaccount:team-a:team-a` → `no`.

### Boundary ② — NetworkPolicy
- Pod network is **flat by default** (any pod → any pod, cross-ns). One standard
  `networking.k8s.io` `NetworkPolicy` per tenant: `podSelector: {}` +
  `ingress: from: [{podSelector: {}}]` = default-deny + same-ns allow. Ingress only;
  egress/DNS stay open.
- **Cilium enforces standard NetworkPolicy** (sufficient). `CiliumNetworkPolicy` is a
  *superset* CRD (L7, `toFQDNs`, cluster-wide) — only when standard can't express it.
- A deny = **timeout**, not "connection refused" (packet dropped, no RST).
- Test from an ephemeral pod (whoami is scratch, no shell):
  `kubectl run probe -n team-a --rm -i --restart=Never --image=curlimages/curl:8.11.1 --command -- curl --max-time 5 http://<team-b-pod-ip>/`

### Boundary ③ — ResourceQuota + LimitRange
- **ResourceQuota** caps namespace totals: `requests.cpu`, `requests.memory`,
  `limits.*`, `pods`, and GPU/extended resources via `requests.<resource>`
  (e.g. `requests.nvidia.com/gpu`, `requests.nvidia.com/mig-3g.40gb`).
- **LimitRange** is the **required companion**: a quota on `requests.cpu` rejects any
  pod that omits a cpu request, so LimitRange supplies `default`/`defaultRequest` +
  `min`/`max` per container. (Note: LimitRange can't default *extended* resources — GPU
  pods must request explicitly.)
- Over-quota pod → `Forbidden: exceeded quota` at **admission** (before scheduling).
  Bare pod → gets LimitRange defaults injected. `kubectl describe resourcequota -n team-a`
  shows Used vs Hard.

### MIG (fake-gpu-operator) — spatial GPU partitioning
- **MIG ≠ time-slicing.** MIG = hardware-isolated slices (dedicated mem/compute);
  time-slicing = temporal sharing, no isolation. Real MIG needs A100/H100 (our A10G
  can't); the fake operator simulates the K8s-facing model.
- **How a slice becomes schedulable:** the device-plugin registers each
  `otherDevices[].name` from the topology **verbatim** as an extended resource. Add a
  separate nodePool to `fake-gpu-operator-values.yaml`:
  ```yaml
  nodePools:
    mig:
      gpuCount: 1            # remaining whole GPU
      otherDevices:
        - { name: nvidia.com/mig-3g.40gb, count: 1 }
        - { name: nvidia.com/mig-1g.10gb, count: 2 }
  ```
  Opt a node in via the GitOps node label `run.ai/simulated-gpu-node-pool: mig`
  (`gpu-nodes.yaml`). Pods then request `nvidia.com/mig-3g.40gb: 1`.
- The `mig-faker` (node label `node-role.kubernetes.io/runai-dynamic-mig=true` + annotation
  `run.ai/mig.config` = mig-parted-style YAML) fakes the GFD discovery labels/mapping —
  but does NOT create schedulable resources; that's `otherDevices`.
- **⚠ Static-topology smell:** the fake operator reads config at startup. After changing
  a running node's MIG: delete the stale `topology-<node>` CM → `kubectl rollout restart
  deploy/status-updater` → restart that node's `device-plugin` pod. Self-heals from git on
  a fresh start.
</content>
