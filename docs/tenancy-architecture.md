# Multi-tenancy architecture (hardway)

How the Flux multi-tenancy setup on the `hardway` cluster works: a **platform**
layer (this repo) that draws the boundaries, and **tenant** layers (separate
per-tenant repos) that fill them — each confined by Flux impersonation + RBAC.

Companion: `docs/CHEATSHEET.md` (concepts/commands), `HANDOFF.md` (state).

---

## 1. The two-layer GitOps control plane

How a commit becomes running workloads. Blue = platform (trusted, cluster-admin),
green = tenant (confined), red = secret.

```mermaid
flowchart TB
  classDef plat fill:#dbeafe,stroke:#1e40af,color:#1e3a8a;
  classDef tenant fill:#dcfce7,stroke:#166534,color:#14532d;
  classDef secret fill:#fee2e2,stroke:#991b1b,color:#7f1d1d;

  subgraph GH["GitHub"]
    FI["fleet-infra<br/>PLATFORM repo (guardrails)"]:::plat
    TARA["tenant-team-a<br/>private · deploy/"]:::tenant
    TBRB["tenant-team-b<br/>private · deploy/"]:::tenant
  end

  subgraph FS["ns: flux-system — controllers run here (cluster-admin)"]
    ROOT["Kustomization: flux-system (root)<br/>path ./clusters/hardway"]:::plat
    INFRA["Kustomization: infrastructure"]:::plat
    APPS["Kustomization: apps (SOPS)"]:::plat
    TEN["Kustomization: tenants (SOPS)"]:::plat
  end

  subgraph NSA["ns: team-a"]
    SAA["SA team-a + RoleBinding→admin<br/>(namespace-scoped)"]:::plat
    SECA["Secret deploy-key<br/>SOPS-decrypted by platform"]:::secret
    GRA["GitRepository team-a"]:::tenant
    KA["Kustomization: team-a<br/>SA=team-a · targetNamespace=team-a"]:::tenant
    WLA["Deployment team-a-whoami<br/>+ ConfigMap team-a-config"]:::tenant
  end

  FI ==>|writeable bootstrap key| ROOT
  ROOT --> INFRA & APPS & TEN
  TEN ==>|"creates guardrails (as cluster-admin)"| SAA & SECA & GRA & KA
  SECA -.->|SSH auth| GRA
  TARA ==>|"read-only deploy key (SSH)"| GRA
  GRA -->|artifact| KA
  KA ==>|"applies AS team-a SA"| WLA

  %% team-b is an identical mirror of the team-a subgraph
```

*(team-b is an exact mirror — same shape, `team-b` everywhere.)*

The platform `tenants` Kustomization (running cluster-admin) creates the
*guardrails*: namespace, SA, RBAC, the decrypted deploy key, and the tenant's own
`GitRepository`+`Kustomization`. That tenant Kustomization then reconciles the
tenant's **separate repo** under a **confined identity**.

---

## 2. The impersonation decision — who applies as whom

The security heart. For *every* Kustomization, Flux picks an identity to impersonate:

```mermaid
flowchart TB
  classDef plat fill:#dbeafe,stroke:#1e40af,color:#1e3a8a;
  classDef tenant fill:#dcfce7,stroke:#166534,color:#14532d;
  classDef deny fill:#fee2e2,stroke:#991b1b,color:#7f1d1d;

  Q{"Kustomization sets<br/>spec.serviceAccountName?"}
  Q -->|"no"| DEF["impersonate &lt;ns&gt;:default<br/>(--default-service-account=default)<br/>powerless → FAILS CLOSED"]:::deny
  Q -->|"yes = kustomize-controller<br/>(infrastructure / apps / tenants)"| PLAT["cluster-admin<br/>platform layer"]:::plat
  Q -->|"yes = team-a<br/>(tenant Kustomization)"| TEN["team-a SA<br/>admin in team-a ONLY<br/>(via RoleBinding, not ClusterRoleBinding)"]:::tenant

  TEN --> OKa["create Deploy/CM/Secret<br/>inside team-a"]:::tenant
  TEN --> NOa["other namespace<br/>or cluster-scoped object<br/>DENIED by apiserver"]:::deny
```

The asymmetry is the whole design: **platform Kustomizations name
`kustomize-controller` (cluster-admin); tenant Kustomizations name their own
ns-scoped SA.** `--default-service-account=default` makes "forgot to name one"
fail safely instead of silently inheriting cluster-admin.

Helm path is identical: helm-controller also honours `--default-service-account`,
so platform HelmReleases name a privileged installer SA (`gpu-operator/helm-installer`,
cluster-admin) while a tenant HelmRelease would name a confined one.

---

## 3. Request-level flow + where the boundary bites

```mermaid
sequenceDiagram
  participant Repo as tenant-team-a repo
  participant SC as source-controller
  participant KC as kustomize-controller
  participant API as kube-apiserver

  Repo->>SC: clone deploy/ (read-only deploy key)
  SC->>KC: built artifact
  Note over KC: impersonate<br/>system:serviceaccount:team-a:team-a
  KC->>API: apply Deployment (→ team-a)
  API-->>KC: allowed (RoleBinding: admin in team-a)
  Note over Repo,API: escape attempt (boundary demo)
  KC->>API: apply ClusterRole (cluster-scoped)
  API-->>KC: FORBIDDEN — team-a SA cannot create clusterroles
  Note over KC: team-a Kustomization → NotReady<br/>boundary proven, team-b unaffected
```

---

## 4. Three independent enforcement layers (don't conflate them)

| Layer | Mechanism | Stops |
|---|---|---|
| **Identity** | `--default-service-account` + per-Kustomization `serviceAccountName` | Flux applying as cluster-admin on a tenant's behalf |
| **RBAC scope** | RoleBinding (ns) vs ClusterRoleBinding (cluster) | the impersonated SA acting outside its namespace |
| **Reference scope** | `--no-cross-namespace-refs` / `--no-remote-bases` | a tenant pointing at another ns's secrets/sources, or remote bases |

---

## 5. Where each piece lives in the repo

```
clusters/hardway/
├── flux-system/kustomization.yaml   # lockdown patches (the 3 flags + root SA pin)
├── infrastructure.yaml              # platform K — serviceAccountName: kustomize-controller
├── apps.yaml                        # platform K (SOPS)  — same SA
└── tenants.yaml                     # platform K (SOPS)  — same SA; applies tenants/hardway
tenants/hardway/
├── kustomization.yaml               # aggregates team-a + team-b
├── team-a/
│   ├── namespace.yaml               # ns team-a
│   ├── rbac.yaml                    # SA team-a + RoleBinding→admin (ns-scoped)
│   ├── deploy-key.secret.yaml       # SOPS-encrypted read-only deploy key (ns team-a)
│   └── sync.yaml                    # GitRepository + Kustomization (impersonation)
└── team-b/ (mirror)
```

Controller lockdown flags (set via JSON6902 patches in
`clusters/hardway/flux-system/kustomization.yaml`):

| flag | kustomize-controller | helm-controller | notification-controller |
|---|:---:|:---:|:---:|
| `--no-cross-namespace-refs=true` | ✓ | ✓ | ✓ |
| `--no-remote-bases=true` | ✓ | — | — |
| `--default-service-account=default` | ✓ | ✓ | — |

Tenant workload repos (the green layer): `slikk66/tenant-team-a`,
`slikk66/tenant-team-b` (private; each a `deploy/` dir; read-only deploy keys).
