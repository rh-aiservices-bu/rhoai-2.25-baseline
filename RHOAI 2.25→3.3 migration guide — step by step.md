# Migrate from Red Hat OpenShift AI 2.25.4 to 3.3.5

> **About this guide.** This is a task-ordered rewrite of the OpenShift AI 2.25.4 → 3.3 migration guide, targeting the current **3.3.5** patch release. Where the reference documentation is organized by *component* (with each component split across a "before upgrade" and an "after upgrade" chapter), this guide is organized by *phase in time* — the actual order a cluster administrator performs the work. Every step from the component-organized guide is preserved; it has simply been re-filed into the phase where you do it.
>
> The single most important idea in this guide is **sequencing**: you migrate a workload *off* a component before you remove the component. Get the order wrong and you lose a running workload with no automated way back.

## The migration at a glance

| Stage | Phase | What you do | Why it's here |
|-------|------:|-------------|---------------|
| Plan | 0. Overview | Understand what changes and why the order matters | Plan before you touch anything |
| Prepare | 1. Pre-flight | Prerequisites, migration approach, cert-manager, verified backup | The only rollback path is a backup |
| Before upgrade | 2. Baseline | Capture a working "before" snapshot of every workload | Proof the migration didn't silently break anything |
| Before upgrade | 3. Assess | Deploy `rhai-cli`, run the lint, submit to Red Hat | Findings drive every remaining phase |
| Before upgrade | 4. Convert model serving | Serverless → RawDeployment, ModelMesh → KServe | Migrate models off removed serving modes |
| Before upgrade | 5. Remediate the platform | Back up stateful components, then disable removed ones | Back up before you flip; flip in dependency order |
| Before upgrade | 6. Workbench images | Triage custom images, bump tags, stop workbenches | Auth and routing models change in 3.x |
| **Upgrade** | 7. Upgrade | Switch channel, approve, wait for the DSC to settle | The actual operator upgrade |
| After upgrade | 8. Post-upgrade verification | Restore config, patch workbenches, migrate Ray, verify every component | Finalize each component on 3.x |
| After upgrade | 9. Re-test | Re-run the Phase 2 tests, diff against the baseline | Prove the workloads survived |
| Clean up | 10. Clean up | Remove leftover 2.x artifacts | Finish clean |

Each phase below opens with a **Phase _N_ of 10** banner showing the stage and objective, so you can track where you are and what comes next.

---

# Phase 0 — Overview

> **Phase 0 of 10 · Plan** — Understand what changes and why sequencing matters, before you touch anything. **Next:** Phase 1 — Pre-flight.

Red Hat OpenShift AI 3.3 is the first 3.x release line to support migration from OpenShift AI 2.25.4 (starting with 3.3.2); this guide targets the current **3.3.5** patch. The 3.x release introduces significant technology and component changes, which is why this is a **migration**, not a routine operator upgrade.

## 0.1 Why this is a migration, not an upgrade

Previous OpenShift AI version bumps were routine operator upgrades. The move to 3.x is different. In a single transition:

- **Components are removed.** KServe Serverless mode, ModelMesh Serving, the embedded Kueue, and CodeFlare are all gone in 3.x. The embedded Service Mesh dependency is dropped. You cannot simply disable these — any workload running on them must be migrated *off first*, or it stops serving.
- **Routing changes.** OpenShift Routes are replaced by the Kubernetes Gateway API. Model endpoint URLs and the dashboard URL change. Capture the new URLs and notify downstream consumers.
- **Authentication changes.** The `oauth-proxy` sidecar is replaced by `kube-rbac-proxy`. Workbenches built for 2.x must be patched, and custom images rebuilt.
- **Schema changes.** HardwareProfiles move to a new API group with renamed objects.

Because so much changes at once, **there is no automated rollback**. OpenShift and OpenShift AI do not support rollbacks once you initiate an in-place migration. The only way back is restoring from a verified backup (Phase 1).

## 0.2 The order that matters

The single most important idea in this guide is **sequencing**. Migrate workloads off a component before you remove the component:

1. **Convert the Serverless InferenceServices to RawDeployment** — so they survive when Serverless mode is removed. (Phase 4)
2. **Migrate the ModelMesh model to KServe** — so it survives when ModelMesh is removed. (Phase 4)
3. **Back up every stateful component** — RayClusters, TrustyAI metrics and data, AI Pipelines DSPAs — *before* the destructive flips. (Phase 5)
4. **Only then disable** Serverless, ModelMesh, Kueue, and CodeFlare on the DSC, and tear down the Service Mesh dependency. (Phase 5)
5. **Handle the workbenches** — bump the images you can, plan rebuilds for the rest, and stop them all. (Phase 6)
6. **Upgrade**, then verify and re-test everything came back. (Phases 7–9)

Get the order wrong — disable a component while a workload still depends on it — and you lose a running model.

## 0.3 The assessment-driven workflow

Red Hat ships an assessment tool, `rhai-cli`, that inspects the cluster and reports what must change. The workflow is a loop:

1. Run `rhai-cli lint` on the 2.25.4 cluster.
2. Remediate the findings marked **critical** or **prohibited**.
3. Re-run the lint to confirm the finding cleared.
4. Only upgrade once the assessment is clean.

**The assessment is not a workload inventory.** It reports *incompatible* workloads and *removed* components — not everything you are running. Compatible workloads (a healthy RawDeployment ISVC, a Feast Feature Store, a KFTO PyTorchJob) will not appear. A clean lint means "nothing blocking," not "nothing to migrate." Always inventory what is actually running (Phase 2) in addition to reading the assessment.

The assessment also surfaces **additions**, not just removals: a finding like `llamastackdistribution / config` is a 3.x prerequisite that does not exist yet, and must be resolved before the upgrade.

## 0.4 Roles and permissions

The migration requires coordination across roles:

- **Cluster administrator** — the primary owner. Performs the upgrade, runs the assessment and helper scripts, and coordinates the other roles. Requires `cluster-admin` and a system with Bash and the `oc` CLI.
- **OpenShift AI administrator** — has dashboard and project access; handles workbench images, custom runtimes, and user groups.
- **OpenShift AI user** (data scientist / ML engineer) — owns application-level artifacts (e.g. LlamaStackDistribution telemetry, pipeline definitions). Involvement is optional if the administrator handles all tasks.

## 0.5 Open a proactive support case

Before you begin, open a proactive support case through the Red Hat Customer Portal at [access.redhat.com](https://access.redhat.com) to let Red Hat know you are planning to migrate to 3.3.5. See [How to submit a Proactive Case](https://access.redhat.com/articles/5387111). You will attach the assessment output to this case in Phase 3.

---

# Phase 1 — Pre-flight

> **Phase 1 of 10 · Prepare** — Meet the prerequisites and take the backup that is your only rollback path. **Next:** Phase 2 — Baseline the workloads.

Complete these checks and preparations before you touch any workload.

## 1.1 Prerequisites

**OpenShift 4.19.9 or later.** Your OpenShift cluster must be at least version 4.19.9. If it is not, upgrade OpenShift first following the [OpenShift Container Platform update documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/updating_clusters/index).

**Kueue management state.** The assessment requires the Kueue component's management state to be `Removed` before you can migrate. You handle the actual change in Phase 5; you can check the current state now:

```
oc get datasciencecluster -A -o jsonpath='{.items[0].spec.components.kueue.managementState}{"\n"}'
```

- `Removed` — ready to migrate.
- `Managed` or `Unmanaged` — you must migrate to the Red Hat build of Kueue and set the state to `Removed` (Phase 5) before upgrading.

## 1.2 Choose your migration approach

There are two approaches. Decide now, because it determines how critical the backup is:

- **Side-by-side migration.** Stand up a second environment running 3.3.5 alongside the untouched 2.25.4 environment, then recreate or move content over. The 2.25.4 environment is left intact, so the risk of unrecoverable state is greatly minimized and a full backup is *recommended* rather than mandatory. Choose this when you can afford a second environment and a longer overlap window.
- **In-place migration.** Modify the single existing environment using the steps in this guide. Choose this when you must migrate within a strict maintenance window. This carries the highest risk because the 2.25.4 environment is directly modified — **a robust, full cluster backup is mandatory, because it is the only rollback mechanism.**

The remainder of this guide documents the **in-place** path.

## 1.3 Notify users

OpenShift AI does not support zero-downtime upgrades. Notify your users of the migration plan and the expected disruption window before you begin.

## 1.4 Install the cert-manager Operator for Red Hat OpenShift

3.x requires the cert-manager Operator. Install it now:

1. In the OpenShift console, go to **Operators → OperatorHub**.
2. Set the **Projects** field to **All projects**.
3. Search for **cert-manager Operator for Red Hat OpenShift**.
4. If the **cert-manager Operator provided by Red Hat** tile is not already labeled **Installed**, install it and wait for it to become ready.

## 1.5 Take a verified backup

For an in-place migration this is the **only** rollback path. Do not proceed without it.

- **etcd snapshot** of the OpenShift control plane.
- **OADP (OpenShift API for Data Protection) backup** of the OpenShift AI namespaces and persistent volumes.

See [OpenShift Container Platform backup and restore](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/backup_and_restore/backup-restore-overview). Verify the backup is restorable before continuing — an untested backup is not a rollback path.

> **Note.** The component-specific backups later in this guide (RayClusters, TrustyAI metrics/data, AI Pipelines DSPAs in Phase 5) protect individual component state during the flips. They do **not** replace the full cluster backup, which is your only whole-cluster rollback.

---

# Phase 2 — Baseline the workloads

> **Phase 2 of 10 · Before upgrade** — Capture a known-good snapshot of every workload to diff against later. **Next:** Phase 3 — Assess the cluster.

Before you change anything, capture what *works* today. A migration without a baseline is just hope: you have no way to tell whether something failed because of the migration or was already broken. Exercise every user-facing workload, save the responses to disk, and keep them — Phase 9 re-runs the *same* tests post-upgrade and diffs against this baseline.

> This phase has no equivalent in the component-organized reference guide. It is strongly recommended for any real migration: a migration that didn't break anything is one you can *prove* didn't break anything.

## 2.1 Inventory the workloads

List everything the migration will touch, and save the output:

```
echo "--- ISVCs ---"
oc get isvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,MODE:.metadata.annotations.serving\.kserve\.io/deploymentMode,URL:.status.url,READY:.status.conditions[?(@.type=="Ready")].status'

echo "--- Workbenches ---"
oc get notebook -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name'

echo "--- DSPAs ---"
oc get dspa -A

echo "--- Ray clusters ---"
oc get raycluster -A
```

Record the deployment mode of every ISVC in particular — the Serverless and ModelMesh ones are the workloads you must convert in Phase 4. If anything is already missing or broken, document it *now* so the migration doesn't take the blame.

## 2.2 Inference-test each model

Discover the served model ID (`/v1/models` for vLLM, `/v2/models/<name>` for OVMS) and send a representative request to each externally reachable ISVC. ISVCs exposed only on a `svc.cluster.local` URL skip the HTTP probe — their predictor pod state is the smoke test.

```
for isvc in $(oc get isvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
  NS="${isvc%/*}"; NAME="${isvc##*/}"
  URL=$(oc get isvc "$NAME" -n "$NS" -o jsonpath='{.status.url}')
  POD_STATE=$(oc get pods -n "$NS" -l serving.kserve.io/inferenceservice="$NAME" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  echo "--- $isvc ---"
  echo "  URL:           $URL"
  echo "  Predictor pod: ${POD_STATE:-no pod}"
  [[ "$URL" != https://* ]] && { echo "  HTTP test:     skipped (cluster-internal only)"; continue; }
  MODEL_ID=$(curl -sk --max-time 10 "${URL}/v1/models" 2>/dev/null | jq -r '.data[0].id // empty')
  if [ -n "$MODEL_ID" ]; then
    REPLY=$(curl -sk --max-time 30 "${URL}/v1/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL_ID\",\"prompt\":\"The capital of France is\",\"max_tokens\":8,\"temperature\":0}" \
      | jq -r '.choices[0].text // "(error)"')
    echo "  vLLM model id: $MODEL_ID"
    echo "  Completion:    $REPLY"
  fi
done
```

Expect every predictor pod `Running` and each externally reachable model to return a sensible response. Save the completions — they are your before-reference.

## 2.3 Confirm workbenches respond

2.x workbenches are exposed through OpenShift Routes. A `200`, `302`, or `303` confirms the pod and Route are healthy:

```
for nb in $(oc get notebook -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
  NS="${nb%/*}"; NAME="${nb##*/}"
  HOST=$(oc get route "$NAME" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null)
  if [ -z "$HOST" ]; then echo "$nb: no Route (workbench may be stopped)"; continue; fi
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${HOST}/")
  echo "$nb https://${HOST}/ -> HTTP $CODE"
done
```

## 2.4 Confirm the DSPA and Ray clusters respond

```
# DSPA: healthz for each pipeline server
TOKEN=$(oc whoami -t)
for dspa in $(oc get dspa -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
  NS="${dspa%/*}"
  DSPA_HOST=$(oc get route -n "$NS" -l app.kubernetes.io/name=data-science-pipelines-operator -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
  echo "--- DSPA $dspa https://${DSPA_HOST} ---"
  curl -sk -H "Authorization: Bearer $TOKEN" "https://${DSPA_HOST}/apis/v2beta1/healthz" | jq .
done

# Ray: cluster state
oc get raycluster -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.workerGroupSpecs[0].replicas,AVAILABLE:.status.availableWorkerReplicas,STATUS:.status.state'
```

Expect DSPA healthz to return healthy and every Ray cluster to show `STATUS=ready` with `AVAILABLE` matching `DESIRED`. Save all output. The cluster's user-visible surface is now known-good.

---

# Phase 3 — Assess the cluster

> **Phase 3 of 10 · Before upgrade** — Deploy rhai-cli, run the assessment, and submit it to Red Hat. **Next:** Phase 4 — Convert the model-serving workloads.

Deploy the `rhai-cli` assessment tool, run the lint, and submit the results to Red Hat. The findings drive every remaining phase.

## 3.1 Deploy a persistent pod with the rhai-cli container image

Deploy a long-lived pod that carries the `rhai-cli` binary and the component helper scripts, with a PVC that persists reports and backup artifacts between sessions.

The container image is `registry.redhat.io/rhoai/rhai-cli-rhel9:v3.3.5`. It contains the `rhai-cli` assessment linter plus component-specific helper scripts for Model Serving, Workbenches, TrustyAI, Llama Stack, AI Pipelines, and Ray.

> **Disconnected environments.** If you are air-gapped, mirror this image to a local registry per your internal procedure before deploying.

**Prerequisites:** the `oc` CLI configured for your cluster; a target namespace; permission to create StatefulSets and PVCs there; and a redhat.com account that can pull from the Red Hat registry.

> **Namespace convention.** This guide runs the rhai-cli pod in a namespace called **`rhai-migration`** and uses that name in every pod-related command (`oc exec`, `oc cp`, cleanup). It is a management namespace, **separate from your workload namespaces** (your model-serving projects, `redhat-ods-applications`, etc.). If you use a different project, create it first (`oc new-project rhai-migration` or your own name) and substitute it consistently wherever you see `rhai-migration` below.

Create the StatefulSet in that namespace:

```
cat <<'EOF' | oc apply -n rhai-migration -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: rhai-cli
spec:
  serviceName: rhai-cli
  replicas: 1
  selector:
    matchLabels:
      app: rhai-cli
  template:
    metadata:
      labels:
        app: rhai-cli
    spec:
      containers:
        - name: rhai-cli
          image: registry.redhat.io/rhoai/rhai-cli-rhel9:v3.3.5
          command:
            - sleep
            - infinity
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
          volumeMounts:
            - name: backup
              mountPath: /tmp/rhoai-upgrade-backup
  volumeClaimTemplates:
    - metadata:
        name: backup
      spec:
        accessModes:
          - ReadWriteOnce
        # storageClassName: <your-storage-class>   # set if PVC stays Pending
        resources:
          requests:
            storage: 1Gi
EOF
```

Wait for the pod to be ready:

```
oc wait pod/rhai-cli-0 -n rhai-migration --for=condition=Ready --timeout=120s
```

If the wait times out, inspect it:

```
oc get pods -n rhai-migration
oc describe pod rhai-cli-0 -n rhai-migration
```

If the PVC stays `Pending`, set `spec.volumeClaimTemplates[0].spec.storageClassName` to a StorageClass in your cluster (ask your OpenShift administrator).

> **Preserve this PVC.** It holds your reports and backup artifacts (`/tmp/rhoai-upgrade-backup`) across sessions. Do not delete it mid-migration.

### The rhai-cli image contents

| Resource | Path | Purpose |
|----------|------|---------|
| CLI binary | `/opt/rhai-cli/bin/rhai-cli` | Cluster scan and migration-readiness analysis (`lint`). |
| Helper scripts | `/opt/rhai-upgrade-helpers/` | Per-component automation. **Not** run by `lint`; you execute them manually in the relevant phase. |

Helper scripts by component (referenced from the phases that use them):

| Component | Path | Key scripts | Used for |
|-----------|------|-------------|----------|
| Model Serving | `/opt/rhai-upgrade-helpers/model-serving/{before,after}-upgrade/` | `serverless-to-raw.sh` | Convert Serverless InferenceServices to RawDeployment mode (Phase 4). |
| | | `modelmesh-to-raw.sh` | Convert ModelMesh (multi-model) InferenceServices to single-model KServe RawDeployment (Phase 4). |
| | | `hardwareprofiles-ignorelist.sh` | Add hardware-profile annotations to the `inferenceservice-config` disallowed list and mark it unmanaged, so KServe doesn't redeploy ISVCs during the upgrade (Phase 5.6). |
| | | `managed-inferenceservice-config.sh` | Restore `inferenceservice-config` to `managed=true` and restart the KServe controller after the upgrade (Phase 8.2). |
| Workbenches | `/opt/rhai-upgrade-helpers/workbenches/` | `workbench-2.x-to-3.x-upgrade.sh` | Verify workbench upgrade-readiness, patch stopped workbenches onto the kube-rbac-proxy auth model, and run a post-upgrade compatibility check (Phases 6.6, 8.3). |
| TrustyAI | `/opt/rhai-upgrade-helpers/trustyai/` | `backup-metrics.sh` / `restore-metrics.sh` | Back up scheduled TrustyAI metrics before upgrade and restore them afterward if data was lost (Phases 5.2, 8.6). |
| | | `break-gpu-deadlock.sh` | Detect and resolve the GPU deployment deadlock between a GPU ISVC and a TrustyAI service (Phase 8.6). |
| | | `migrate-gorch-otel-exporter.sh` | Rewrite `GuardrailsOrchestrator` `spec.otelExporter` to the 3.x schema (Phase 8.5). |
| | | `patch-guardrails-deployment.sh` | Add the missing ReadinessProbe to `GuardrailsOrchestrator` deployments (Phase 8.5). |
| Llama Stack | `/opt/rhai-upgrade-helpers/llamastack/` | `backup-all-llamastack.sh` | Archive pre-upgrade LlamaStackDistribution configuration/data for reference (Phase 5.4). |
| AI Pipelines | `/opt/rhai-upgrade-helpers/ai_pipelines/` | `check_before_upgrade.sh` | Snapshot DSPA pod health and detect deprecated resources / RBAC issues before upgrade (Phase 5.3). |
| | | `update_dsp_role.sh` | Update custom DSP RBAC roles flagged by the pre-upgrade check (Phase 5.3). |
| | | `post_upgrade_check.sh` | Verify AI Pipelines server pods are healthy after upgrade, diffing against the pre-upgrade snapshot (Phase 8.7). |
| Ray | `/opt/rhai-upgrade-helpers/ray/` | `ray_cluster_migration.py list` | Show all RayClusters and their migration status (Phases 5.1, 8.4). |
| | | `ray_cluster_migration.py pre-upgrade` | Back up RayCluster CRs, run prerequisite checks, and set CodeFlare to `Removed` in the DSC (Phase 5.1). |
| | | `ray_cluster_migration.py post-upgrade` | Migrate RayClusters in-place for KubeRay under 3.x (add `--from-backup` to recreate from backup) (Phase 8.4). |
| Kubeflow Trainer | `/opt/rhai-upgrade-helpers/kubeflow-trainer/` | `kubeflow-trainer-verification.sh` | Verify the KFTO v1 operator can create PyTorchJobs after upgrade (Phase 8.7). |

## 3.2 Log in to the cluster from within the pod

The assessment uses *your* credentials, not the pod service account. First open a shell **on the pod** — this command runs on your workstation and drops you into a new interactive shell inside the container:

```
oc exec -it rhai-cli-0 -n rhai-migration -- /bin/bash
```

Then, **inside that pod shell**, point `KUBECONFIG` at a writable path, put the CLI on your `PATH` so you can call it as `rhai-cli`, and log in:

```
export KUBECONFIG=/tmp/.kubeconfig
export PATH="/opt/rhai-cli/bin:$PATH"
oc login --token=<token> --server=<api-server-url>
```

> The rest of this guide invokes the linter as `rhai-cli lint …` (relying on the `PATH` entry above). If you open a **fresh** shell in the pod later — for example when you return for the post-upgrade phases — re-run the `export PATH=…` line, or call the binary by its full path `/opt/rhai-cli/bin/rhai-cli`.

## 3.3 Run the migration assessment

> **Important.** `rhai-cli lint` is a read-only diagnostic — it makes no changes. Run it on the **2.25.4** cluster; run against an already-upgraded cluster and it will not report correctly. (The helper scripts, by contrast, *do* modify resources when you run them.)

Full cluster scan:

```
rhai-cli lint --target-version 3.3.5
```

Filter to one component to reduce noise (wrap the component string in `*`):

```
rhai-cli lint --target-version 3.3.5 --checks *datasciencepipelines*
```

| Component | `--checks` value |
|-----------|------------------|
| Dashboard | `*dashboard*` |
| AI Pipelines | `*datasciencepipelines*` |
| TrustyAI Guardrails | `*guardrails*` |
| KServe | `*kserve*` |
| Kueue | `*kueue*` |
| Llama Stack | `*llamastackdistribution*` |
| Model Serving (ModelMesh) | `*modelmesh*` |
| Workbenches | `*notebook*` |
| Ray Training Operator | `*ray*` |
| Kubeflow Training Operator | `*trainingoperator*` |

### Reading the results

Each row has a **STATUS** icon (`✗` critical, `⚠` warning, `✓` info), a **GROUP** (dependency / service / component / workload), a **KIND** (e.g. `kserve`, `notebook`, `cert-manager`), a **CHECK** type, an **IMPACT**, and a **MESSAGE** describing the required action.

| Impact | Meaning | Action |
|--------|---------|--------|
| `prohibited` | Upgrade is not possible. | Do not continue. |
| `critical` | A blocker; the component/workload will fail. | Fix using the relevant phase or helper script. |
| `warning` | Potential issue or deprecated field. | Review and remediate for long-term stability. |
| `info` | Prerequisite met / no action needed. | None. |

**Before upgrading, ensure no `prohibited` or `critical` items remain.** After you resolve each blocker in the phases that follow, re-run `lint` to confirm it cleared. Expect the critical count to fall as you progress — and note that resolving one item can surface new ones (e.g. 3.x prerequisites that don't exist yet).

## 3.4 Submit the assessment output to Red Hat

Write the assessment to YAML and attach it to your proactive support case:

```
rhai-cli lint --target-version 3.3.5 --output yaml > /tmp/rhoai-upgrade-backup/rhai-cli-output.yaml
```

Copy it from the pod to your workstation (run from outside the pod):

```
oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup/rhai-cli-output.yaml ./rhai-cli-output.yaml
```

Then, if you have not already, open a proactive support case at [access.redhat.com](https://access.redhat.com) ([How to submit a Proactive Case](https://access.redhat.com/articles/5387111)) and upload the YAML as an attachment ([How to provide files to Red Hat Support](https://access.redhat.com/solutions/2112)). You will re-run and re-submit the assessment as you clear blockers.

---

# Phase 4 — Convert the model-serving workloads

> **Phase 4 of 10 · Before upgrade** — Move every model off the removed Serverless/ModelMesh modes onto RawDeployment. **Next:** Phase 5 — Remediate the platform.

This is the heart of the migration. 3.x removes both **Serverless** and **ModelMesh** deployment modes, so every InferenceService (ISVC) running on them must be moved to **RawDeployment** — the only serving mode 3.x supports — *before* you disable those components in Phase 5. Convert first; disable later. Disable a serving mode while a model still depends on it and the model stops serving.

> **Complete this phase only if you have Serverless or ModelMesh workloads.** ISVCs already on RawDeployment are 3.x-compatible and need no work. Confirm your workload types with `rhai-cli` (below); if you are already RawDeployment-exclusive, skip to Phase 5.

## 4.1 Migration impact and scope

**If you do not migrate:**

- All ISVCs using Serverless or ModelMesh return **HTTP 503 Service Unavailable** after the operator upgrade.
- Distributed inference workloads using `LLMInferenceService` fail without the new authentication configuration.
- Cluster-wide components (OpenShift Serverless, Service Mesh v2, standalone Authorino) become unsupported and must be removed (Phase 5).

**What 3.3 removes:** Serverless deployment mode; ModelMesh (multi-model) deployment mode; the OpenShift Serverless Operator integration; the OpenShift Service Mesh v2 integration; and the standalone Authorino Operator (replaced by Red Hat Connectivity Link for `LLMInferenceService`).

All model-serving workloads must move to **RawDeployment**, which uses standard Kubernetes `Deployment` resources without serverless infrastructure.

## 4.2 Prerequisites for model-serving migration

- Cluster-admin access, authenticated via `oc`.
- Project-level access to namespaces containing `InferenceService` and `LLMInferenceService` resources.
- **You have audited the cluster for other consumers of OpenShift Service Mesh v2** and confirmed they can be migrated or removed.

> **Important — Service Mesh conflict.** If you cannot remove Service Mesh v2 because of other dependencies, you must upgrade those applications to [Service Mesh v3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/migrating_from_service_mesh_2_to_service_mesh_3/) *before* upgrading OpenShift AI. If a conflicting OSSM v2.x subscription is present when the Gateway API `GatewayClass` is created, the Cluster Ingress Operator fails to install the required OSSM v3.x components — Gateway API resources have no effect and no proxy routes traffic. Resolve this conflict before continuing.

## 4.3 Run the serving-focused assessment

From inside the `rhai-cli` container, check the KServe and ModelMesh state:

```
rhai-cli lint --target-version 3.3.5 --verbose --checks "*kserve*" --checks "*modelmesh*"
```

Interpret the rows:
- **workload / kserve** — ISVCs that need migration.
- **component / kserve or modelmeshserving** — cluster configuration changes needed (Phase 5).
- **dependency** — operator install/removal requirements (Phase 5).

## 4.4 Enumerate what needs converting

List every ISVC that is *not* already RawDeployment:

```
oc get isvc -A -o json | jq -r '.items[]
  | select((.metadata.annotations."serving.kserve.io/deploymentMode" // "") != "RawDeployment")
  | "\(.metadata.namespace)\t\(.metadata.name)\t\(.metadata.annotations."serving.kserve.io/deploymentMode")"'
```

Every Serverless and ModelMesh ISVC in that list must be converted. Already-RawDeployment ISVCs are filtered out and left alone.

> **Why a helper script instead of `oc patch`.** The KServe admission webhook **rejects in-place edits of `deploymentMode`** on an existing ISVC. Conversion is therefore *backup-and-recreate*: capture the spec, delete the old object, and create a fresh RawDeployment-shaped one. The helper scripts do this for you; the manual fallback is documented in KB [7134025](https://access.redhat.com/articles/7134025).

## 4.5 Convert Serverless InferenceServices to RawDeployment

`serverless-to-raw.sh` is the official helper. It is interactive: it checks prerequisites, discovers Serverless ISVCs in a namespace, prompts you to select which to convert, and handles the authentication resources (ServiceAccount, Role, RoleBinding) and storage credentials automatically.

**1. Identify Serverless ISVCs:**

```
rhai-cli lint --target-version 3.3.5 --verbose --checks "*kserve*" --isvc-deployment-mode serverless
```

The output lists impacted objects with `NAME`, `NAMESPACE`, and `DEPLOYMENT MODE`. For each namespace listed, run the conversion.

**2. Preview with `--dry-run`:**

```
/opt/rhai-upgrade-helpers/model-serving/before-upgrade/serverless-to-raw.sh --dry-run -n <namespace>
```

The script stops at two interactive prompts:

- **Selection prompt** — enter `all` (or specific numbers) to choose which ISVCs to migrate.
- **Resource naming** — choose **`1) Use original names`** for in-place replacement (keeps the ISVC name identical, so your Phase 2 baseline and Phase 9 re-test still resolve it by name), or `2) -raw suffix` for side-by-side. Prefer **option 1** for an in-place migration.

In dry-run mode it writes the generated YAML under `/tmp/rhoai-upgrade-backup/model-serving/serverless-to-raw/<isvc>/` (an `original/` snapshot and a rewritten copy). Review these files.

**3. Apply.** Re-run without `--dry-run`, adding `--delete-existing` so the script removes the legacy ISVC, ServingRuntime, ServiceAccount, RoleBinding, and Istio Route in one shot and applies the RawDeployment replacements:

```
/opt/rhai-upgrade-helpers/model-serving/before-upgrade/serverless-to-raw.sh --delete-existing -n <namespace>
```

Answer the same two prompts (`all`, then `1`).

**4. Verify** each converted ISVC is `RawDeployment` and `Ready`:

```
oc get isvc -n <namespace> -o json | jq -r '["NAME","DEPLOYMENT_MODE","READY"], (.items[] | [.metadata.name, .status.deploymentMode, (.status.conditions[] | select(.type=="Ready") | .status)]) | @tsv' | column -t
```

Repeat for every namespace, then confirm no Serverless ISVCs remain anywhere:

```
oc get isvc -A -o json | jq -r '.items[]
  | select((.metadata.annotations."serving.kserve.io/deploymentMode" // "") == "Serverless"
        or (.status.deploymentMode // "") == "Serverless")
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

## 4.6 Convert ModelMesh InferenceServices to RawDeployment

ModelMesh is *multi-model serving* — one ServingRuntime hosts many models keyed by a storage path. 3.x has no ModelMesh, so each model is re-deployed as a *single-model* KServe RawDeployment ISVC backed by a single-model ServingRuntime, pointing `storageUri` at the same model data. For a natively-supported format (ONNX, OpenVINO IR) this is a true re-host — no model conversion, no data movement.

`modelmesh-to-raw.sh` is the official helper. It discovers ModelMesh ISVCs, prompts you to select models and a runtime template, configures storage, and creates the new RawDeployment ServingRuntime + ISVC.

The script has two flag combinations:

- `--from-ns <A> --target-ns <B>` — cross-namespace; supports `--dry-run` for a safe preview. Source and target must differ.
- `--from-ns <A> --preserve-namespace` — *in-place*; destructive; **cannot** be combined with `--dry-run`. The two interactive prompts (which ISVCs, which runtime template) are the safety net — you can `q` out before anything is applied. To preview YAML first, dry-run against a throwaway target namespace.

**1. Identify ModelMesh ISVCs:**

```
rhai-cli lint --target-version 3.3.5 --verbose --checks "*kserve*" --isvc-deployment-mode modelmesh
```

The output lists each impacted ISVC with its **namespace** — you'll need that namespace for the next steps.

**2. Release the model-store PVC if it is ReadWriteOnce** (skip on RWX storage — EFS, CephFS, NFS). An RWO PVC (the default on many storage classes, e.g. `gp3-csi`) attaches to only one node at a time, so if the ModelMesh runtime keeps the volume the new RawDeployment pod may land on another node and hang with a `Multi-Attach error`. Using the namespace from step 1, first **discover the ModelMesh runtime name**, then scale it to zero to release the volume:

```
# Find the multi-model (ModelMesh) ServingRuntime in the ISVC's namespace
oc -n <namespace> get servingruntime

# Scale that runtime to zero and wait for its pod to drain
oc -n <namespace> patch servingruntime <mm-runtime> --type=merge -p '{"spec":{"replicas":0}}'
oc -n <namespace> wait --for=delete pod -l name=modelmesh-serving-<mm-runtime> --timeout=120s
```

**3. Run the conversion** (in-place example):

```
/opt/rhai-upgrade-helpers/model-serving/before-upgrade/modelmesh-to-raw.sh --from-ns <namespace> --preserve-namespace
```

> **Run this helper interactively (with a TTY), and pick a listed template — not the manual option.** The script is fragile when driven non-interactively (piped input, or `oc exec` without `-it`): the manual-template path (the `m` option) corrupts the template name and produces a broken ServingRuntime. Run it from a real terminal, and at the template prompt accept the default with `d` or type the **number** of a listed template. If you can't run it interactively, or it still fails, use the manual fallback in the note below — it is the reliable path for PVC-backed models.

At the prompts: enter `all` to select the ISVCs, then choose the runtime template that matches the model format:

| Model format | Runtime template |
|--------------|------------------|
| ONNX or OpenVINO IR | `kserve-ovms` (single-model OVMS) — **not** the multi-model `ovms` |
| LLM via vLLM (CPU) | `vllm-cpu-runtime-template` |
| LLM via vLLM (NVIDIA GPU) | `vllm-cuda-runtime-template` |
| Caikit-wrapped LLM | `caikit-tgis-serving-template` |

Press `d` to accept the default if it matches; otherwise type the number. `--preserve-namespace` keeps the original ISVC name — only `.status.deploymentMode` flips from `ModelMesh` to `RawDeployment`.

**4. Check the events for the known storage-block bug** — do this *before* checking readiness, because if the bug hit, the ISVC will never reach `Ready` and you need to fix it first. Look for a webhook rejection on the new ISVC:

```
oc get events -n <namespace> --sort-by=.lastTimestamp | tail -20
```

If the events show no webhook rejection, the conversion is clean — continue to step 5. If you *do* see the rejection below, the converter hit a known bug; apply the fix, then continue.

> **Known `modelmesh-to-raw.sh` bug — PVC storage block not translated.** For a PVC-backed model the script may copy the ModelMesh storage block (`storage: { key: ..., path: ... }`) verbatim into the new ISVC, which the RawDeployment webhook rejects (so the predictor pod never starts and the ISVC stays not-`Ready`):
> ```
> admission webhook "inferenceservice.kserve-webhook-server.pod-mutator" denied the request:
> storage type must be one of [s3, hdfs, webhdfs]. storage type [pvc] is not supported
> ```
> Fix it by patching the ISVC to the KServe `storageUri` form:
> ```
> oc patch isvc <name> -n <namespace> --type=json -p='[
>   {"op":"remove","path":"/spec/predictor/model/storage"},
>   {"op":"add","path":"/spec/predictor/model/storageUri","value":"pvc://<pvc-name>/<model-path>"}
> ]'
> ```
> `pvc://<pvc-name>/<model-path>` points at the model root; OVMS auto-discovers the version subdirectory.

> **Reliable fallback — build the RawDeployment ISVC by hand (KB [7134025](https://access.redhat.com/articles/7134025)).** If the helper corrupts the template name or the PVC-storage patch above doesn't stick, skip the helper for that model and create a fresh single-model RawDeployment ISVC directly. Reference the same PVC via `storageUri` (no `storage` block at all), and select a matching single-model runtime (e.g. `kserve-ovms` for ONNX/OpenVINO). For example, for an OVMS model at `mobilenet/` on the `model-store` PVC:
> ```
> oc apply -f - <<'EOF'
> apiVersion: serving.kserve.io/v1beta1
> kind: InferenceService
> metadata:
>   name: <name>
>   namespace: <namespace>
>   annotations:
>     serving.kserve.io/deploymentMode: RawDeployment
> spec:
>   predictor:
>     model:
>       modelFormat:
>         name: onnx
>       runtime: kserve-ovms
>       storageUri: pvc://model-store/mobilenet
> EOF
> ```
> This is a fresh object, so the webhook accepts it (it only blocks *changing* mode on an existing ISVC). Then delete the legacy ModelMesh ISVC and its multi-model ServingRuntime (step 6).

**5. Verify** the ISVC reaches `RawDeployment` / `Ready=True`:

```
oc get isvc <name> -n <namespace> -o jsonpath='mode={.status.deploymentMode} ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

**6. Delete the legacy ModelMesh ISVCs and multi-model ServingRuntimes** from the source namespace (after confirming the new RawDeployment services work). For in-place `--preserve-namespace` these usually return zero rows already; the sweep catches leftovers from cross-namespace or `-raw`-suffix runs:

```
# Leftover ModelMesh ISVCs
oc get isvc -n <namespace> -o json | jq -r '.items[]
  | select(.status.deploymentMode == "ModelMesh" or .metadata.annotations["serving.kserve.io/deploymentMode"] == "ModelMesh")
  | .metadata.name' | while read -r name; do echo "Deleting ModelMesh ISVC: $name"; oc delete isvc "$name" -n <namespace>; done

# Multi-model ServingRuntimes
oc get servingruntimes.serving.kserve.io -n <namespace> -o json | jq -r '.items[]
  | select(.spec.multiModel==true) | .metadata.name' \
  | while read -r name; do echo "Deleting ServingRuntime: $name"; oc delete servingruntime "$name" -n <namespace>; done
```

## 4.7 Confirm every model is RawDeployment

Before moving on, confirm the entire serving surface is RawDeployment and healthy:

```
oc get isvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,MODE:.metadata.annotations.serving\.kserve\.io/deploymentMode,STATUS:.status.deploymentMode,READY:.status.conditions[?(@.type=="Ready")].status'

# Count of non-RawDeployment ISVCs — must be 0
oc get isvc -A -o json | jq -r '[.items[] | select((.metadata.annotations."serving.kserve.io/deploymentMode" // "") != "RawDeployment")] | length'
```

Zero non-RawDeployment ISVCs means it is safe to disable Serverless and ModelMesh in Phase 5. Re-run the readiness check inside the container:

```
rhai-cli lint --target-version 3.3.5 --verbose --checks "*kserve*"
```

Expect no critical KServe/ModelMesh workload findings.

## 4.8 Prepare distributed inference (LLMInferenceService)

> **Complete this section only if you run distributed inference (`llm-d`) with `LLMInferenceService`.** Otherwise skip to Phase 5. This section needs cluster-admin *and* model-owner collaboration: admins install operators and configure Red Hat Connectivity Link; users configure authentication and freeze their `LLMInferenceService` resources.

### Install Red Hat Connectivity Link (RHCL)

In 3.x, the standalone Authorino Operator is replaced by RHCL for `LLMInferenceService` authentication.

1. In the console, go to **Operators → OperatorHub** and search for **Red Hat Connectivity Link**. If already installed, skip to step 3.
2. Install it into the **`kuadrant-system`** namespace (create the project if needed), and wait until ready.
3. Create and configure the Kuadrant/Authorino resources from inside the `rhai-cli` container or your terminal:

```
# Kuadrant CR
oc apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
EOF

oc wait Kuadrant -n kuadrant-system kuadrant --for=condition=Ready --timeout=10m

# Serving cert for Authorino
oc annotate svc/authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert -n kuadrant-system

# Enable TLS on Authorino
oc apply -f - <<EOF
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: authorino
  namespace: kuadrant-system
spec:
  replicas: 1
  clusterWide: true
  listener:
    tls:
      enabled: true
      certSecretRef:
        name: authorino-server-cert
  oidcServer:
    tls:
      enabled: false
EOF

oc wait --for=condition=ready pod -l authorino-resource=authorino -n kuadrant-system --timeout=150s
```

Verify the operator CSV shows `Succeeded`, the Kuadrant resource shows `Ready`, and the Authorino pods are `Running` `1/1`:

```
oc get csv -n kuadrant-system | grep rhcl
oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions}'
oc get pods -n kuadrant-system -l authorino-resource=authorino
```

See [Installing Connectivity Link on OpenShift](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.2/html/installing_connectivity_link_on_openshift/index).

### Disconnected environments (RHCL)

Only if running distributed inference air-gapped. Identify the `wasm-shim` image SHA from the [wasm-shim-rhel9 catalog page](https://catalog.redhat.com/en/software/containers/rhcl-1/wasm-shim-rhel9/672a1e565d865456f8f2835f), then:

1. Create `wasm-plugin-pull-secret` in `openshift-ingress` from the cluster pull secret:
   ```
   oc get secret pull-secret -n openshift-config -o json | \
     jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.ownerReferences)' | \
     jq '.metadata.name="wasm-plugin-pull-secret"' | \
     oc apply -n openshift-ingress -f -
   ```
2. Patch the `rhcl-operator` Subscription with the mirrored WASM image (`RELATED_IMAGE_WASMSHIM`, `PROTECTED_REGISTRY`) using your mirror registry and the wasm-shim SHA.
3. Inject `WASM_INSECURE_REGISTRIES` into the Gateway pod via a `<gateway>-config` ConfigMap in `openshift-ingress` and reference it from the Gateway's `infrastructure.parametersRef`.

(Full command forms are in the reference guide §2.8.10.2.)

### Configure authentication for LLMInferenceService

In 3.3.2+, distributed inference is **secure by default** — unauthenticated clients get **HTTP 403**. Choose one:

- **Disable auth (dev/test only):**
  ```
  oc annotate llminferenceservice <name> -n <namespace> security.opendatahub.io/enable-auth=false
  ```
- **RBAC access control (recommended):** create a `ServiceAccount`, a `Role` granting `get` on the named `llminferenceservices` resource, and a `RoleBinding`; then have clients send `Authorization: Bearer $(oc create token <sa> -n <namespace>)`.

Verify all `LLMInferenceService` resources are `Ready`:

```
oc get llminferenceservices --all-namespaces
```

### Freeze LLMInferenceService configuration

Pin `LLMInferenceService` resources to the 2.25.4 templates to prevent scheduler-pod failures during the upgrade:

```
oc patch llmisvc <name> -n <namespace> --subresource=status --type=merge \
  -p '{"status":{"annotations":{"serving.kserve.io/config-llm-template":"kserve-config-llm-template","serving.kserve.io/config-llm-decode-template":"kserve-config-llm-decode-template","serving.kserve.io/config-llm-worker-data-parallel":"kserve-config-llm-worker-data-parallel","serving.kserve.io/config-llm-decode-worker-data-parallel":"kserve-config-llm-decode-worker-data-parallel","serving.kserve.io/config-llm-prefill-template":"kserve-config-llm-prefill-template","serving.kserve.io/config-llm-prefill-worker-data-parallel":"kserve-config-llm-prefill-worker-data-parallel","serving.kserve.io/config-llm-scheduler":"kserve-config-llm-scheduler","serving.kserve.io/config-llm-router-route":"kserve-config-llm-router-route"}}}'
```

> **Important — scheduler argument breaking changes in 3.3.2+.** If you override `LLMInferenceService` scheduler arguments, update them for 3.x: arguments changed from `camelCase` to `kebab-case` (e.g. `--certPath` → `--cert-path`); the default TLS cert path moved from `/etc/ssl/certs` to `/var/run/kserve/tls`; signed TLS via the OpenShift service signer is now mandatory; and you must include the `--cert-path` argument and an `SSL_CERT_DIR` environment variable.

## 4.9 Verify migration readiness

Run a comprehensive readiness check inside the container:

```
rhai-cli lint --target-version 3.3.5 --checks "*kserve*" --checks "*modelmesh*"
```

**Do not proceed to the upgrade while any critical issue remains.** Address every critical finding via the relevant procedure and re-run `lint` until clean. (Note: the `inferenceservice-config` ConfigMap backup and hardware-profile ignorelist update, and the cluster-configuration disables, are handled in Phase 5.)

## Troubleshooting

**`oc apply` of a recreated ISVC fails with a `deploymentMode` webhook error.** This should not happen with the helper scripts, which create the RawDeployment ISVC as a *fresh* object (the webhook only blocks *changing* mode on an existing object). If you took the manual fallback, confirm you flipped the annotation in the backup and deleted the old ISVC before re-applying.

**A recreated ISVC sits `READY=False` for minutes.** RawDeployment pulls and loads the model fresh; a CPU model can take a few minutes. Watch the predictor pod, and check its logs if it never becomes ready:

```
oc get pods -n <ns> -l serving.kserve.io/inferenceservice=<name>
```

**Can't delete a multi-model ServingRuntime — "still in use".** Delete the ModelMesh ISVC that references it first; the runtime can only be removed once no ISVC references it.

**`oc delete isvc` on a leftover Serverless ISVC hangs in `Terminating` forever.** This is a finalizer deadlock — and the reason you convert and delete every Serverless ISVC *before* Phase 5 removes Serverless and Service Mesh. A Serverless ISVC's finalizer cleans up the Knative `Service` and Istio `VirtualService` it owns; if those components are already gone, the finalizer can't reach their APIs and never clears. Recovery: if the operators are still installed, re-enable Serverless/Service Mesh, let the delete finish, then remove them in the right order. If they are already uninstalled, force-clear the finalizer and recreate the model as RawDeployment:

```
oc patch isvc <name> -n <ns> --type=merge -p '{"metadata":{"finalizers":null}}'
```

then sweep for orphaned `ksvc`/`virtualservice`. The rule: never disable a component while a workload still depends on it.

---

# Phase 5 — Remediate the platform (before upgrade)

> **Phase 5 of 10 · Before upgrade** — Back up stateful components, then disable the removed ones in dependency order. **Next:** Phase 6 — Handle the workbench images.

With every model on RawDeployment, it is safe to start the platform work — but only in the *right order*. Real clusters carry stateful workloads (RayClusters, TrustyAI services, AI Pipelines) whose data must be captured *before* you flip the components that host them, because some flips destroy state. The rule for this whole phase: **back up before you flip, and flip in dependency order.**

Ordering within the phase:

1. Back up everything with persistent state — **RayClusters, TrustyAI, AI Pipelines** — while the components that own the backup logic are still installed.
2. **Delete LlamaStackDistributions** (delete-and-replace; no upgrade path).
3. Verify the components you are *not* demoing — **Model Registry, Feature Store, KFTO** — are healthy and inventoried.
4. Back up and update the **`inferenceservice-config` ConfigMap** (after every ISVC is RawDeployment, before the disables).
5. **Disable the removed components** — Kueue, Ray/CodeFlare, ModelMesh, KServe Serverless — then tear down the **Service Mesh** dependency.
6. **Uninstall the 2.x serving operators** and confirm a clean assessment.

## 5.1 Back up the RayClusters

CodeFlare is removed in 3.x; KubeRay takes over RayCluster management. Existing RayCluster CRs survive the controller swap, but back them up first in case reconciliation drops fields.

> **Run this only when you are ready to upgrade.** The Ray `pre-upgrade` command sets `codeflare` to `Removed` in the DSC. CodeFlare provides essential security configuration for user-created RayClusters — if you run this and then *delay* the upgrade, users could create RayClusters while CodeFlare is absent and expose them to security issues.

The `ray_cluster_migration.py` helper is idempotent and non-destructive (it never deletes anything unless you use `--from-backup`). From inside the container:

```
# Pre-upgrade check + backup. Also sets codeflare=Removed in the DSC.
python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py pre-upgrade

# List RayClusters and their migration status
python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py list
```

> **Flooded with `InsecureRequestWarning`?** If you run this helper against a cluster whose API server uses an untrusted certificate (common on ephemeral/RHDP clusters), urllib3 prints an `Unverified HTTPS request is being made…` warning on *every* API call, burying the script's output. Suppress Python warnings for the session — this hides the warnings (which go to stderr) without affecting the script's own output:
> ```
> export PYTHONWARNINGS=ignore
> ```
> Set this once and it applies to every `python3` invocation in your shell (including the `post-upgrade` step in Phase 8.4). To silence only the TLS warning and keep any others, use `export PYTHONWARNINGS="ignore:Unverified HTTPS request"` instead; for a one-off, prefix the command with `python3 -W ignore …`. Running the helper from *inside* the `rhai-cli` pod avoids this entirely — the in-cluster API certificate is trusted there.

The pre-upgrade check verifies permissions and cert-manager, then saves each RayCluster CR to two subdirectories under `/tmp/rhoai-upgrade-backup/ray/`:

- `rhoai-2.x/` — CRs with CodeFlare components; use **only** to restore RayClusters if you abandon the 3.x upgrade.
- `rhoai-3.x/` — CRs for proceeding with the 3.x upgrade.

Copy the backup off the pod, and confirm every cluster is still `ready`:

```
oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup/ray ./ray-backup
oc get raycluster -A
```

(The helper backs up CR *configuration* only, not RayCluster runtime state — warn users of temporary downtime.)

## 5.2 Back up TrustyAI metrics, data, and Guardrails config

TrustyAI's storage schema changed between 2.x and 3.x; historical bias-detection metrics and training data can become unreadable without a pre-upgrade snapshot.

**Skip this section** if TrustyAI is not `Managed`:

```
oc get dsc -A -o jsonpath='{.items[0].spec.components.trustyai.managementState}{"\n"}'
oc get trustyaiservice -A
```

If `Managed` and TrustyAIServices exist, for **each** namespace back up metrics and data. Create the backup dir and set `BACKUP_DIR` explicitly:

> **Set `BACKUP_DIR` explicitly.** The rhai-cli image does not always set it for non-login shells. An unset `BACKUP_DIR` makes `curl -o "$BACKUP_DIR/..."` silently write to the filesystem root, where cleanup tooling won't find it.

```
export BACKUP_DIR=/tmp/rhoai-upgrade-backup/trustyai
mkdir -p "$BACKUP_DIR"
export NS=<namespace>
export TAS_NAME=$(oc get trustyaiservice -n "$NS" -o jsonpath='{.items[0].metadata.name}')
export SVC_PORT=$(oc get svc -n "$NS" "$TAS_NAME" -o jsonpath='{.spec.ports[?(@.name=="http")].port}')

# Metrics — port-forward + curl (no helper script for metrics)
oc port-forward -n "$NS" "svc/$TAS_NAME" 8080:${SVC_PORT} &
PF_PID=$!; sleep 3
curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
  http://localhost:8080/metrics/all/requests \
  -o "${BACKUP_DIR}/trustyai-metrics-${NS}-$(date +%Y%m%d-%H%M%S).json"
kill $PF_PID 2>/dev/null

# Data — backup-data.sh auto-detects PVC vs DATABASE from the TrustyAIService CR
cd /opt/rhai-upgrade-helpers/trustyai
./backup-data.sh --namespace "$NS"
```

`backup-data.sh` writes PVC data to `trustyai-data-<ns>-<timestamp>/data/` or a MariaDB dump to `trustyai-db-<ns>-<timestamp>/dump.sql`, each with a `metadata.json`. Two harmless warnings you may see: `cannot use rsync: rsync not available in container` (it falls back to `tar`) and `PVC appears to be empty (0 files copied)` (no bias-detection has run yet). Both still complete successfully.

**Guardrails Orchestrator otelExporter.** If any `GuardrailsOrchestrator` exports traces/metrics, back up its `spec.otelExporter` so you can restore it post-upgrade (no helper script for this):

```
oc get guardrailsorchestrator -A -o json \
  | jq -r '.items[] | select(.spec.otelExporter != null) | {ns: .metadata.namespace, name: .metadata.name, otelExporter: .spec.otelExporter}' \
  > ${BACKUP_DIR}/guardrails-otel-backup-$(date +%Y%m%d%H%M).json
```

Copy the whole TrustyAI backup off the pod:

```
oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup/trustyai ./trustyai-backup
```

## 5.3 AI Pipelines pre-upgrade check

DSPA pipelines keep running across the upgrade, but the schema changed — deprecated fields (the old `instructLab` block) and any leftover `v1alpha1` DSPA CRs need detection. The helper snapshots every DSPA pod's health to disk (so `post_upgrade_check.sh` can diff against it in Phase 8), then scans for deprecated APIs and custom RBAC roles:

```
cd /opt/rhai-upgrade-helpers/ai_pipelines
./check_before_upgrade.sh
```

On a clean cluster this passes with nothing to remediate. It may report:

- **Deprecated `instructLab` field** — safe to ignore; tolerated during upgrade.
- **Deprecated `v1alpha1` DSPA found** — run `./update_dsp_role.sh` (or update each CR) to move to `v1`.
- **Custom RBAC roles that require updates** — consult the teams that use AI Pipelines, then run `./update_dsp_role.sh`. If the roles are GitOps/ArgoCD-managed, this is advisory; update the source.

Re-run `./check_before_upgrade.sh` until it reports no remaining issues.

## 5.4 Delete the LlamaStackDistributions

Llama Stack's 2→3 transition is **delete-and-replace**. The schema changed (SQLite → PostgreSQL, the VectorDB API was removed, the Inference API became OpenAI-compatible), and there is **no in-place data migration** — existing LSDs cannot be carried across. You will deploy fresh 3.x-shaped LSDs in Phase 8.

> **Disconnected environments:** skip this section — Llama Stack disconnected support starts in OpenShift AI 3.0.
>
> **Warning:** this results in complete loss of existing Llama Stack data — agent state, vector DB metadata and embeddings, telemetry, file metadata, everything in SQLite.

**Cluster admin:** identify every LSD and its owners, and notify them to archive if they care about in-pod state:

```
oc get llamastackdistribution --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,Created:.metadata.creationTimestamp
oc get rolebindings -n <namespace> -o wide   # identify owners
```

**LSD owner (optional archive):** the `backup-all-llamastack.sh` helper archives configuration to `/tmp/rhoai-upgrade-backup/llamastack-backups-<date>/` for *reference only* — the SQLite databases cannot be imported into 3.3's PostgreSQL:

```
export BACKUP_DIR=<path>
mkdir -p $BACKUP_DIR
/opt/rhai-upgrade-helpers/llamastack/backup-all-llamastack.sh
```

**Delete every LSD** (this also clears the `llamastackdistribution / config` critical finding — a 3.x prerequisite that does not exist yet):

```
oc get llamastackdistribution -A -o json \
  | jq -r '.items[]? | "\(.metadata.namespace) \(.metadata.name)"' \
  | while read NS NAME; do oc delete llamastackdistribution "$NAME" -n "$NS"; done
```

When recreating in Phase 8, owners must port client code to the 3.x APIs: the `VectorDB` API → `Vector_IO`; Completions → OpenAI-compatible format; embeddings → external embedding-model endpoint; and review agent creation/interaction code. See [Working with Llama Stack (3.3)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/working_with_llama_stack/index).

## 5.5 Verify the components you are not migrating

These components continue through the upgrade with no spec changes, but you should confirm they are healthy and capture an inventory to compare against post-upgrade.

**Model registry and catalog.** Confirm the registry/catalog pods are `Running` and error-free, and that registries show **Available** in the dashboard (**Settings → Model registry settings**):

```
oc get pods -n rhoai-model-registries
```

> During the upgrade the catalog/registry may briefly be inaccessible while pods respin. After upgrade the dashboard navigation moves to **AI hub → Registry** and **Catalog** — notify users. (Verified in Phase 8.)

**Feature Store.** Tech Preview in 2.25.4, GA in 3.3.2; otherwise unchanged. If you use it, confirm each instance is `Ready` and a sample materialization job completes:

```
oc get featurestores --all-namespaces
oc get featurestores -n <namespace>
# Trigger a job from an existing CronJob and confirm it completes
oc create job test --from=cronjob/<cronjob-name> -n <namespace>
oc get jobs -n <namespace>
```

**Kubeflow Training Operator (KFTO).** PyTorchJobs continue running through the upgrade. Capture the list now to compare post-upgrade:

```
oc get pytorchjobs -A
```

> KFTO v1 is deprecated as of 2.25.4 and planned for removal in favor of Kubeflow Trainer v2. Also note: if you later do an OpenShift (OCP) upgrade, node drains can interrupt PyTorchJobs — ensure none are running, or that running ones checkpoint.

## 5.6 Back up and update the inferenceservice-config ConfigMap

With every ISVC on RawDeployment, apply the hardware-profile ignorelist changes. This must happen **after** conversion (Phase 4) and **before** the disables below, so the upgrade reconciler honors the new ignorelist.

Back up first (run on your workstation / any `oc` session — the ConfigMap lives in the applications namespace):

```
oc get configmap inferenceservice-config -n redhat-ods-applications -o yaml \
  > /tmp/rhoai-upgrade-backup/inferenceservice-config-backup.yaml
```

Then run the helper from inside the container. It adds `opendatahub.io/hardware-profile-name` and `opendatahub.io/hardware-profile-namespace` to the disallowed list (so HardwareProfiles migrate cleanly) and marks the ConfigMap `opendatahub.io/managed=false` so InferenceServices are not redeployed during the upgrade:

```
/opt/rhai-upgrade-helpers/model-serving/before-upgrade/hardwareprofiles-ignorelist.sh -n redhat-ods-applications
```

Verify the ignorelist is applied and the `managed=false` annotation is present:

```
oc get configmap inferenceservice-config -n redhat-ods-applications -o yaml | grep hardware -B2 -A2
```

> **Side effect of `managed=false`:** the upgrade will **not** redeploy your model-serving pods — they keep their current kserve runtime image. If you want a fresh runtime image post-upgrade (e.g. a newer vLLM build), restart each predictor explicitly after Phase 7 once the platform is healthy.

## 5.7 Disable the removed components

Flip each removed component to `Removed` on the DSC. Because you migrated every workload off these components in Phase 4, removing them no longer affects a running workload.

**Kueue — the highest-risk removal.** Left `Managed` at upgrade time, its admission webhook intercepts Job creation cluster-wide; during the upgrade the webhook and its CRDs can fall out of sync and reject Job submissions for *any* workload.

> If you were on embedded Kueue with state `Managed`, you must first migrate to the Red Hat build of Kueue per the [2.25 Kueue migration guide](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.25/html/managing_openshift_ai/managing-workloads-with-kueue#migrating-to-the-rhbok-operator_kueue). Before starting, preserve your enabled frameworks by annotating the config map (default applications namespace is `redhat-ods-applications`):
>
> ```
> oc annotate configmap kueue-manager-config -n <applications_namespace> opendatahub.io/managed=false
> ```

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": { "components": { "kueue": { "managementState": "Removed" } } }
}'
```

The `KueueReady` condition flips to `False / reason=Removed` — expected.

**Ray and CodeFlare** (two separate DSC components, even though the assessment reports the blocker under `ray/removal`; the Ray pre-upgrade script in 5.1 already set `codeflare`):

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": { "components": {
    "codeflare": { "managementState": "Removed" },
    "ray":       { "managementState": "Removed" }
  } }
}'
```

**ModelMesh Serving:**

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": { "components": { "modelmeshserving": { "managementState": "Removed" } } }
}'
```

**KServe Serverless mode** — set `serving` to `Removed` *and* the default mode to `RawDeployment` in one patch:

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": { "components": { "kserve": {
    "serving": { "managementState": "Removed" },
    "defaultDeploymentMode": "RawDeployment"
  } } }
}'
```

The Knative stack tears down over several minutes. First poll until it has drained — re-run this until it reports `No resources found`:

```
oc get knativeserving -A
```

Once drained, confirm every model still serves (RawDeployment models don't depend on Knative):

```
oc get isvc -A -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
```

## 5.8 Remove the Service Mesh dependency

OpenShift 4.19+ handles service mesh internally, so 3.x no longer needs the embedded one. Remove it from the DSCI, wait for the SMCP to drain, then delete the leftover ServiceMeshMemberRoll:

```
oc patch $(oc get dsci -o name | head -n1) --type=merge -p '{
  "spec": { "serviceMesh": { "managementState": "Removed" } }
}'

# Wait for the SMCP to drain, then remove the SMMR
until [ -z "$(oc get smcp -A --no-headers 2>/dev/null)" ]; do echo "Waiting for SMCP to drain..."; sleep 5; done
oc delete smmr default -n istio-system --ignore-not-found
```

> **Why the SMMR needs an explicit delete.** The DSCI change drains the SMCP but leaves the `ServiceMeshMemberRoll` with a `maistra.io/istio-operator` finalizer that only the still-installed Service Mesh operator can clear. **Delete the SMMR before uninstalling the operator** (next step). If you already uninstalled the operator and the SMMR hangs, reinstall it briefly so the finalizer processes, then delete the SMMR.

## 5.9 Uninstall the 2.x serving operators

OpenShift Serverless, Service Mesh 2, and standalone Authorino were dependencies of the 2.x KServe Serverless stack. With that stack removed, uninstall them (CLI form shown; the console equivalent is **Operators → Installed Operators → ⋮ → Uninstall Operator**, selecting "Delete all operand instances"):

```
# Standalone Authorino — only if Red Hat Connectivity Link is NOT installed
# (in 3.x, Authorino is needed only via RHCL for LLMInferenceService)
oc -n openshift-operators delete subscription authorino-operator --ignore-not-found
oc get csv -A 2>/dev/null | awk '/authorino-operator\./ {print "-n "$1, $2}' | xargs -L1 oc delete csv

# OpenShift Serverless
oc -n openshift-serverless delete subscription serverless-operator --ignore-not-found
oc get csv -A 2>/dev/null | awk '/serverless-operator\./ {print "-n "$1, $2}' | xargs -L1 oc delete csv

# Service Mesh 2 — safe now that the SMCP and SMMR are gone
oc -n openshift-operators delete subscription servicemeshoperator --ignore-not-found
oc get csv -A 2>/dev/null | awk '/servicemeshoperator\./ {print "-n "$1, $2}' | xargs -L1 oc delete csv
```

> **Do not remove `servicemeshoperator3` (OSSM v3).** Only the v2 operator (`servicemeshoperator`) is a leftover here. `servicemeshoperator3` is installed by the Cluster Ingress Operator to back the 3.x **Gateway API** — it is a required part of the new platform, not a migration remnant. The `awk` filters above use `servicemeshoperator\.` (literal dot) so they match only v2 and never touch v3; if you uninstall via the console, pick **Red Hat OpenShift Service Mesh 2**, not the v3 operator.

Verify none remain (this should return nothing — note the trailing `\.` so OSSM v3 isn't flagged):

```
oc get csv -A | grep -E 'authorino-operator\.|serverless-operator\.|servicemeshoperator\.' | grep -v rhods
```

## 5.10 Final pre-upgrade readiness

Prepare the OpenShift AI Operator subscription and confirm the cluster is upgrade-ready.

1. **Set the OpenShift AI subscription Update approval to `Manual`** (if not already). This prevents an automatic upgrade when you change the channel in Phase 7.
2. Verify the current CSV is `Succeeded`, and the DSC and DSCI are `Ready`:
   ```
   oc get csv -n redhat-ods-operator
   oc get dsc  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'
   oc get dsci -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'
   ```
   Reconciliation can take time — do not proceed if the DSC/DSCI show errors.
3. Confirm operator and component pods are `Running` / `Ready=True` in `redhat-ods-operator` and `redhat-ods-applications`.
4. **Re-run the full assessment** and confirm zero critical findings:
   ```
   rhai-cli lint --target-version 3.3.5 | grep -E 'Total:|FAIL|PASS'
   ```

`Failed: 0` and a `Ready` DSC mean the platform is upgrade-ready.

## Troubleshooting

**`oc delete smmr` hangs.** The member roll's finalizer is processed by the Service Mesh 2 operator. Delete the SMMR *before* uninstalling the operator (5.8 before 5.9). If you already uninstalled it, reinstall it briefly so the finalizer can process, then delete the SMMR.

**A converted model goes `READY=False` during the Serverless teardown.** Check the predictor pod and its logs:

```
oc get pods -n <ns> -l serving.kserve.io/inferenceservice=<name>
```

RawDeployment models don't depend on Knative, so the teardown itself shouldn't affect them; pod restarts later during the upgrade are expected.

**KServe Serverless teardown seems stuck.** It can take 5–10 minutes. Watch the Knative pods fall to zero; if it never drains, check the controller logs:

```
oc get pods -n knative-serving
oc logs -n redhat-ods-applications -l app=kserve-controller-manager
```

---

# Phase 6 — Handle the workbench images

> **Phase 6 of 10 · Before upgrade** — Triage and fix workbench images, then stop every workbench. **Next:** Phase 7 — Perform the upgrade.

The last thing to handle before the upgrade is the workbenches. 3.x changes both the workbench **authentication** model (`oauth-proxy` → `kube-rbac-proxy`) and **routing** (OpenShift Routes → Kubernetes Gateway API with path-based routing). Out-of-the-box (OOTB) images are bumped by the operator, but **custom (BYON) images** and **out-of-date image tags** need attention.

> **All steps here must be completed before the upgrade.** Unmigrated workbenches stay on the 2.x auth layer and, combined with `NB_PREFIX` routing conflicts, hit redirection loops or connectivity failures during the transition — especially RStudio, code-server, and custom images.

## Considerations before you start

- **Coordinate with users** to prevent loss of unsaved work. Every workbench must end up **Stopped** (or Running-then-stopped); if one can't reach Running, stop or delete it before migrating.
- **Workbench URLs change** after the upgrade — users get new URLs from the dashboard; bookmarks break.
- **Custom images must be rebuilt** for `kube-rbac-proxy` auth and Gateway API path routing (below). 2.x custom images are not compatible.
- **RStudio** workbenches require a new build from the RStudio BuildConfig *after* the upgrade, and must be on the `latest` tag.
- Workbenches created in 2.25.4 or earlier are **unsupported** in 3.3 unless migrated.

## 6.1 Discover custom (BYON) workbench images

List the custom ImageStreams registered through the dashboard:

```
oc get imagestream -n redhat-ods-applications -l app.kubernetes.io/created-by=byon \
  -o custom-columns='NAME:.metadata.name,URL:.metadata.annotations.opendatahub\.io/notebook-image-url'
```

Any image built before 3.x (e.g. an upstream community Jupyter image) will not work as-is after the upgrade.

## 6.2 Why 2.x custom images break in 3.x — and how to rebuild

A custom workbench image built for 2.x makes two assumptions that 3.x breaks. **The fix is a rebuild of the image, not a cluster-side config tweak — Red Hat does not auto-rebuild custom images; this is an application-owner task.**

1. **Authentication.** In 2.x each workbench pod ran an `oauth-proxy` sidecar coupled to the OpenShift OAuth server. In 3.x the platform injects `kube-rbac-proxy`. An image that bakes in oauth-proxy configuration fights the platform and produces redirect loops. **Remove all oauth-proxy binary/config/sidecar wiring** — the image only needs to serve the notebook on its own port.
2. **Routing.** In 2.x workbenches were exposed through Routes. In 3.x they are behind Gateway API with **path-based routing**, where each workbench lives under a prefix carried in the `NB_PREFIX` environment variable. The server must serve under that prefix *and* must not strip it from redirects. For a Jupyter image, pass `NB_PREFIX` to `--ServerApp.base_url` at launch via a custom entrypoint:

```
#!/bin/bash
set -euo pipefail
exec jupyter lab \
  --ServerApp.base_url="${NB_PREFIX:-/}" \
  --ServerApp.ip=0.0.0.0 --ServerApp.port=8888 \
  --ServerApp.token='' --ServerApp.password='' \
  --ServerApp.allow_origin='*' --ServerApp.open_browser=False --ServerApp.quit_button=False
```

The Containerfile change is minimal: drop any oauth-proxy wiring, `COPY` the entrypoint in, and set it as `ENTRYPOINT` (replacing the upstream `start-notebook.sh`, which ignores `NB_PREFIX`).

> **Gotchas.** Build for the cluster architecture (`--platform linux/amd64` — an arm64 image fails with `exec format error`). Production images should rebase on UBI9 + Python from `registry.redhat.io`. **NGINX-fronted images (code-server, RStudio)** need two extra fixes Jupyter doesn't: keep `NB_PREFIX` in every `Location:` redirect header, and serve `/api` as a `302` rather than an inline rewrite (avoids 403s).

See [Introducing the Kubernetes Gateway API for custom image migration](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/managing_resources/introducing-kubernetes-gateway-api_resource-mgmt).

## 6.3 Re-register the ImageStream with the rebuilt image

Once rebuilt and published, point the custom ImageStream at the new image and update the dashboard registration:

```
oc tag <registry>/<rebuilt-image>:3.x custom-<name>:3.x \
  -n redhat-ods-applications --reference-policy=local

oc annotate imagestream custom-<name> -n redhat-ods-applications \
  opendatahub.io/notebook-image-url="<registry>/<rebuilt-image>:3.x" --overwrite
```

`--reference-policy=local` pins the ImageStream to the cluster's internal registry; if you host the image there, also grant `system:image-puller` to the workbench ServiceAccount for `redhat-ods-applications`. See [Importing a custom workbench image](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/managing_openshift_ai/creating-custom-workbench-images#importing-a-custom-workbench-image_custom-images).

## 6.4 Bump out-of-date image tags

Evaluate whether OOTB image tags need updating:

- **Jupyter-based** workbenches — *recommended* to update to the latest tag (`2025.2`).
- **code-server** workbenches — **required** to be on `2025.2`.
- **RStudio** (BuildConfig) — **required** to be on `latest`; needs a fresh build *after* the upgrade.

Find any code-server workbench on an old tag, then bump them all in one loop:

```
oc get notebooks -A -o json \
  | jq -r '.items[]
      | select(.spec.template.spec.containers[0].image | test("code-?server"))
      | select(.spec.template.spec.containers[0].image | test(":2025\\.[01]$"))
      | "\(.metadata.namespace)/\(.metadata.name)"' \
  | while read -r nb; do
      NS="${nb%/*}"; NAME="${nb##*/}"
      oc patch notebook "$NAME" -n "$NS" --type=json \
        -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/code-server-notebook:2025.2"}]'
    done
```

## 6.5 Stop every workbench

All workbenches must be stopped before the upgrade. The notebook controller treats the `kubeflow-resource-stopped` annotation as "stopped if present" (use a timestamp, not the literal `true`):

```
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for row in $(oc get notebooks -A --no-headers | awk '{print $1"/"$2}'); do
  ns="${row%/*}"; name="${row##*/}"
  oc -n "$ns" annotate notebook "$name" kubeflow-resource-stopped="$STAMP" --overwrite
done
```

## 6.6 Verify workbench readiness

Run the compatibility check — **PASS** or **WARNING** is upgrade-ready; a **FAIL** must be resolved first:

```
rhai-cli lint --target-version 3.3.5 --checks "*notebook*"
```

The check reports image compatibility buckets (compatible / custom-needs-verification / incompatible-rebuild-after / etc.) and confirms all notebooks are stopped. Confirm no workbench has running pods:

```
oc get notebooks -A -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,RUNNING:.status.readyReplicas,STARTED:.status.containerState.running.startedAt"
```

Every `RUNNING` value should be `0`/`<none>`.

## Troubleshooting

**`oc tag` can't reach the image.** Confirm the image URL is correct and public, or add a pull secret for the registry to `redhat-ods-applications`.

**A workbench from the custom image still redirect-loops in 3.x.** The image wasn't rebuilt correctly — confirm oauth-proxy is fully removed and the server honors `NB_PREFIX`. Use the rebuilt image, not the original.

**A workbench won't stop — its pod keeps coming back.** Confirm the annotation applied:

```
oc get notebook <name> -n <ns> -o jsonpath='{.metadata.annotations.kubeflow-resource-stopped}'
```

The controller treats *any* non-empty value as stopped — use a timestamp, not `true`.

---

# Phase 7 — Perform the upgrade

> **Phase 7 of 10 · Upgrade** — Switch to the migration channel, approve the OLM upgrade, then move to stable. **Next:** Phase 8 — Post-upgrade verification.

The cluster is pre-upgrade-clean: models on RawDeployment, removed components disabled, 2.x operators uninstalled, workbenches stopped, the assessment clean. Now trigger the upgrade by switching the operator subscription to a dedicated **migration channel** and approving the OLM upgrade as it walks to 3.3.5.

The migration channel (`support-required-upgrade`) is separate from the normal release channels so the upgrade cannot be triggered by accident.

> **Before you start:** log out of the OpenShift AI dashboard (no zero-downtime upgrade). Confirm one last time that the assessment shows zero critical findings. **Disconnected environments** must first mirror the exact OSSM v3 version the Cluster Ingress Operator requires — see below.

## 7.1 Inspect the current subscription

Approval should already be `Manual` (set in Phase 5.10), forcing you to approve each step:

```
oc -n redhat-ods-operator get subscription rhods-operator \
  -o jsonpath='channel={.spec.channel}{"\n"}approval={.spec.installPlanApproval}{"\n"}installedCSV={.status.installedCSV}{"\n"}'
```

See which channels the catalog offers:

```
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}  {.currentCSV}{"\n"}{end}' | grep -E 'support-required-upgrade|stable-3'
```

## 7.2 (Disconnected only) mirror the required OSSM v3

Skip for connected environments. For disconnected, identify the OSSM version and channel the Cluster Ingress Operator requires, then mirror exactly that version:

```
oc set env deployment/ingress-operator -n openshift-ingress-operator --list | grep GATEWAY_API_OPERATOR_VERSION | sed 's/.*=//'
oc set env deployment/ingress-operator -n openshift-ingress-operator --list | grep GATEWAY_API_OPERATOR_CHANNEL | sed 's/.*=//'
```

Create an `ImageSetConfiguration` for `servicemeshoperator3` pinned to that `minVersion`/`maxVersion` and channel, run `oc-mirror --v2` into your mirror registry, apply the generated cluster resources (ensuring the CatalogSource is named `redhat-operators`), and verify the version is available:

```
oc get packagemanifest -o json | jq '.items[] | select(.metadata.name=="servicemeshoperator3" and .status.catalogSource=="redhat-operators") | .status.channels[] | select(.name=="<ossm-channel>") | .entries[].name'
```

## 7.3 Switch to the migration channel

```
oc -n redhat-ods-operator patch subscription rhods-operator --type=merge -p '{
  "spec": { "channel": "support-required-upgrade" }
}'
```

Confirm OLM generates an (unapproved) InstallPlan:

```
oc -n redhat-ods-operator get installplan \
  -o custom-columns='NAME:.metadata.name,CSV:.spec.clusterServiceVersionNames[0],APPROVED:.spec.approved'
```

## 7.4 Approve the upgrade

> OLM walks the upgrade graph **one release at a time** — it does not jump straight to 3.3.x. From a recent 2.25 patch you'll see one InstallPlan; from an earlier patch you may see two in sequence. Each needs its own approval (Manual approval mode).

This loop approves each unapproved InstallPlan and waits until the 3.3.x CSV reports `Succeeded` (adjust the CSV version to your target patch, e.g. `rhods-operator.3.3.5`):

```
deadline=$(( $(date +%s) + 1800 ))
while (( $(date +%s) < deadline )); do
  IP=$(oc -n redhat-ods-operator get installplan -o json \
    | jq -r '.items[] | select(.spec.approved==false) | .metadata.name' | head -1)
  if [ -n "$IP" ]; then
    echo "Approving InstallPlan $IP ..."
    oc -n redhat-ods-operator patch installplan "$IP" --type=merge -p '{"spec":{"approved":true}}'
    sleep 30; continue
  fi
  phase=$(oc -n redhat-ods-operator get csv rhods-operator.3.3.5 -o jsonpath='{.status.phase}' 2>/dev/null)
  echo "rhods-operator.3.3.5 phase: ${phase:-<pending>}"
  [ "$phase" = "Succeeded" ] && break
  sleep 30
done
```

Confirm the new CSV is `Succeeded` and no `rhods-operator.2.*` CSV remains:

```
oc get csv -n redhat-ods-operator | grep rhods-operator
```

## 7.5 Wait for the DSC and DSCI to settle

The new operator reconciles the DSC and DSCI under the 3.x model. Wait for both to return to `Ready`:

```
oc wait --for=jsonpath='{.status.phase}'=Ready dsc/$(oc get dsc -o jsonpath='{.items[0].metadata.name}') --timeout=20m
oc get dsci -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'
```

## 7.6 Move off the migration channel

The `support-required-upgrade` channel is a one-shot trigger — it does not advance to later 3.3.x patches, so leaving the subscription there means no ongoing z-stream updates. Move to the stable 3.3 channel:

```
oc patch subscription rhods-operator -n redhat-ods-operator --type=merge -p '{
  "spec": { "channel": "stable-3.3" }
}'
```

> Choose `stable-3.3` (stays on the 3.3 z-stream) rather than `stable-3.x` (which would eventually offer a 3.4 minor upgrade — a separate planning decision). If you had bookmarked dashboard URLs, recreate redirects now per [KB 7137771](https://access.redhat.com/solutions/7137771).

Verify the subscription is on `stable-3.3`, state `AtLatestKnown`, on the 3.3.x CSV:

```
oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='channel={.spec.channel} state={.status.state} installedCSV={.status.installedCSV}{"\n"}'
```

## Troubleshooting

**The approval loop times out without reaching `Succeeded`.** Check the operator logs:

```
oc logs -n redhat-ods-operator deploy/rhods-operator --tail=50
```

A stuck InstallPlan usually means a removed component was left `Managed` — re-run the assessment (Phase 3) to find which, fix it, and the upgrade resumes.

**No InstallPlan appears after the channel switch.** Confirm the channel is exactly `support-required-upgrade` and that the catalog offers it:

```
oc get packagemanifest rhods-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}'
```

**OLM stalls mid-walk with a stale `ResolutionFailed` / `ConstraintsNotSatisfiable` — no new InstallPlan appears.** Because OLM walks the graph one release at a time (7.4), it can wedge *between* hops — commonly after the intermediate 2.25.z step — reporting `ConstraintsNotSatisfiable` even though the bundle unpack jobs have already completed successfully. This is a stale resolver state, not a real dependency conflict. Restart the OLM catalog-operator to force a re-resolve; the next InstallPlan (e.g. the 3.3.x one) then appears within seconds:

```
oc rollout restart deployment/catalog-operator -n openshift-operator-lifecycle-manager
oc rollout status  deployment/catalog-operator -n openshift-operator-lifecycle-manager --timeout=120s
oc -n redhat-ods-operator get installplan   # the next hop's InstallPlan should now be present
```

Check the subscription's condition to recognize this case before restarting: `oc -n redhat-ods-operator get subscription rhods-operator -o jsonpath='{.status.conditions}' | jq` shows `type: ResolutionFailed, status: "True"`. Confirm the unpack jobs are `Complete` (`oc get jobs -n openshift-marketplace`) so you know it's a stale resolve and not a genuine constraint problem.

**DSC stays `Not Ready` after the upgrade.** Inspect which component is unhealthy:

```
oc get dsc <name> -o jsonpath='{.status.conditions}' | jq
```

Phase 8 covers verifying the platform and Gateway.

---

# Phase 8 — Post-upgrade verification (after upgrade)

> **Phase 8 of 10 · After upgrade** — Finalize each component on 3.x and verify the whole platform. **Next:** Phase 9 — Re-test the migrated workloads.

The operator is on 3.3.5 and the DSC is `Ready`, but the migration isn't finished. The 3.x reconciler needs several helper scripts to bring components fully across (ConfigMap state, workbench auth, RayCluster CRs, Guardrails schema, TrustyAI data), and then every component must be verified. Work through this phase in order.

## 8.1 Confirm platform health

Verify the operator, DSC, DSCI, pods, and the Gateway:

```
oc get csv -n redhat-ods-operator | grep rhods-operator            # 3.3.x, Succeeded; no 2.* CSV
oc get dsc  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'    # Ready
oc get dsci -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'    # Ready
oc get pods -n redhat-ods-operator     -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,STATUS:.status.phase'
oc get pods -n redhat-ods-applications -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,STATUS:.status.phase'
oc get gatewayconfigs --all-namespaces -o wide                     # default-gateway READY: True
```

Then click the **Red Hat OpenShift AI** link in the OpenShift console and confirm the dashboard loads.

> **Kueue after upgrade.** Confirm `KueueReady` is `True`, or `False` with reason `Removed` (both are healthy). If it reports `Managed is not supported`, the pre-upgrade Kueue migration was incomplete — complete the Red Hat build of Kueue migration now.
>
> **Disconnected OSSM troubleshooting.** If OSSM-dependent components don't become ready (failed `servicemeshoperator3` subscription, DSCI not `Ready`, `data-science-gateway` `Unknown`), see [KB 7141146](https://access.redhat.com/solutions/7141146).

## 8.2 Restore the inferenceservice-config ConfigMap

In Phase 5 you set `inferenceservice-config` to `managed=false` so the upgrade couldn't redeploy your ISVCs. Hand control back. The `managed-inferenceservice-config.sh` helper restores the annotation, restarts the KServe controller, and verifies no ISVC was silently redeployed:

```
/opt/rhai-upgrade-helpers/model-serving/after-upgrade/managed-inferenceservice-config.sh -n redhat-ods-applications
```

Verify `managed=true`, then confirm each ISVC has only **one** active ReplicaSet (an extra ReplicaSet scaled to 0 alongside the active one signals an unwanted redeployment). The ReplicaSets live in the **ISVC's own namespace** — your model-serving projects, not `redhat-ods-applications` — so list the ISVCs first to find those namespaces:

```
# 1. Confirm the ConfigMap is back under management
oc get configmap inferenceservice-config -n redhat-ods-applications -o jsonpath='managed={.metadata.annotations.opendatahub\.io/managed}{"\n"}'

# 2. Find which namespaces hold InferenceServices
oc get isvc -A

# 3. In each ISVC namespace from step 2, check the ReplicaSets
oc get replicasets -n <isvc-namespace> -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp,REPLICAS:.status.replicas'
```

To sweep every ISVC namespace at once instead of running step 3 per namespace:

```
for ns in $(oc get isvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "--- $ns ---"
  oc get replicasets -n "$ns" -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp,REPLICAS:.status.replicas'
done
```

> If you were managing a customized `inferenceservice-config` manually before the upgrade, skip the helper and just verify.

## 8.3 Patch the workbenches onto the new auth model

Workbenches still carry 2.x oauth-proxy configuration; under 3.x they need `kube-rbac-proxy` or they hit redirect loops on first start. First confirm the notebook controllers are up:

```
oc get deployment -n redhat-ods-applications odh-notebook-controller-manager notebook-controller-deployment
```

Then patch every stopped workbench in place:

```
cd /opt/rhai-upgrade-helpers/workbenches
./workbench-2.x-to-3.x-upgrade.sh patch --only-stopped --with-cleanup -y
```

Verify none remain on the legacy layer (`Legacy (2.x): 0` / "All workbenches have been migrated"):

```
./workbench-2.x-to-3.x-upgrade.sh list --all
```

Notify users they can restart their workbenches, and confirm they can reach the IDE.

> **Custom images** that bake in oauth-proxy cannot be fixed by this patch — they need an image rebuild against `kube-rbac-proxy` (Phase 6). The helper flags them.
>
> **Deferred image migration.** If users couldn't stop all workbenches before the upgrade, they can migrate images afterward: bump tags (Jupyter `2025.2` recommended, code-server `2025.2` required, RStudio `latest` + rebuild), then either edit-and-save the workbench in the dashboard (it patches automatically) or delete and recreate it **using the same PVC** to avoid data loss. Unmigrated workbenches keep running on the 2.x auth layer and risk redirect loops.

## 8.4 Migrate the RayClusters to KubeRay

CodeFlare is gone; KubeRay manages Ray clusters directly. Complete the workbench migration (8.3) first, then run the post-upgrade migration (your Phase 5.1 backups are the safety net). Preview with `--dry-run` if desired:

```
python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py list          # all show NEEDS MIGRATION
python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py post-upgrade   # answer yes; or --cluster/--namespace for one
```

Each migrated cluster restarts its head + worker pods (temporary downtime). Verify every RayCluster returns to `ready`:

```
oc get raycluster -A
```

## 8.5 Patch the GuardrailsOrchestrators

Two helpers per GuardrailsOrchestrator: `patch-guardrails-deployment.sh` adds the missing ReadinessProbe; `migrate-gorch-otel-exporter.sh` rewrites `spec.otelExporter` to the 3.x schema. Check first, then fix:

```
oc get guardrailsorchestrator -A -o json \
  | jq -r '.items[]? | "\(.metadata.namespace) \(.metadata.name)"' \
  | while read -r NS GORCH_NAME; do
      echo "=== $NS/$GORCH_NAME ==="
      cd /opt/rhai-upgrade-helpers/trustyai
      ./patch-guardrails-deployment.sh --gorch-name "$GORCH_NAME" --namespace "$NS" --fix
      ./migrate-gorch-otel-exporter.sh --namespace "$NS" --fix
    done
```

Verify each orchestrator's `/info` endpoint reports every service `HEALTHY`:

```
GORCH_ROUTE_HEALTH=$(oc get routes -n <namespace> "<gorch-name>-health" -o jsonpath='{.spec.host}')
curl -sSk "https://${GORCH_ROUTE_HEALTH}/info" -H "Authorization: Bearer $(oc whoami -t)" | jq .
```

## 8.6 Verify TrustyAI and restore data if needed

Confirm the TrustyAI operator is healthy, then compare current metric counts against your Phase 5.2 backups to detect data loss:

```
oc wait --for=condition=Available deployment/trustyai-service-operator-controller-manager -n redhat-ods-applications --timeout=120s

export BACKUP_DIR=/tmp/rhoai-upgrade-backup/trustyai
export NS=<namespace>
export TAS_NAME=$(oc get trustyaiservice -n "$NS" -o jsonpath='{.items[0].metadata.name}')
export SVC_PORT=$(oc get svc -n "$NS" "$TAS_NAME" -o jsonpath='{.spec.ports[?(@.name=="http")].port}')
oc port-forward -n "$NS" "svc/$TAS_NAME" 8080:${SVC_PORT} & PF_PID=$!
CURRENT=$(curl -sk -H "Authorization: Bearer $(oc whoami -t)" http://localhost:8080/metrics/all/requests | jq '.requests | length')
BACKUP=$(jq '.requests | length' "$(ls -t ${BACKUP_DIR}/trustyai-metrics-${NS}-*.json | head -1)")
kill $PF_PID 2>/dev/null
[ "$CURRENT" -ge "$BACKUP" ] && echo "OK: no data loss" || echo "DATA LOSS: restore needed"
```

**If DATA LOSS**, restore metrics from the backup. Determine the TrustyAI route label, dry-run, then restore:

```
export BACKUP_FILE=$(ls -t ${BACKUP_DIR}/trustyai-metrics-${NS}-*.json | head -1)
export ROUTE_LABEL='trustyai-service-name=<tas-name>'    # confirm via: oc get route -n "$NS" --show-labels
./restore-metrics.sh --namespace "$NS" --file "$BACKUP_FILE" --route-label "$ROUTE_LABEL" --dry-run
./restore-metrics.sh --namespace "$NS" --file "$BACKUP_FILE" --route-label "$ROUTE_LABEL" --skip-existing
```

Each metric should show `Successfully scheduled`, summary `Failed: 0`. (Restored metrics receive new UUIDs; original IDs are not preserved. Data-storage/PVC restores use the corresponding data restore path.)

> **GPU deployment deadlock.** On GPU clusters, a new GPU-based ISVC pod in a namespace with a running TrustyAI service can stay `Pending` indefinitely while the old pod keeps running. Detect and break it:
> ```
> oc get pods -A | grep predictor        # look for a 0/N Pending predictor
> ./break-gpu-deadlock.sh --namespace <ns> --check
> ./break-gpu-deadlock.sh --namespace <ns> --fix
> ```

## 8.7 Verify the non-core components

**Model registry and catalog.** Confirm the pods are `Running` (note: the catalog now has **two** pods — `model-catalog` and `model-catalog-postgres`), and that registries show **Available** in the dashboard. **The dashboard navigation moved to AI hub → Registry and Catalog** — notify users and recreate any bookmarked-URL redirects.

```
oc get pods -n rhoai-model-registries
```

**Feature Store** (now GA). Confirm the operator pod runs, every instance is `Ready`, and a sample materialization job completes:

```
oc get pods -n redhat-ods-applications | grep feast-operator
oc get featurestores --all-namespaces
oc create job postupgradetest --from=cronjob/<cronjob-name> -n <namespace> && oc get jobs -n <namespace>
```

Then verify in the dashboard under **Develop & train → Feature Store** (new Gateway URL).

**AI Pipelines.** Run the post-upgrade check (diffs against the Phase 5.3 snapshot), then have pipeline users import and run a pipeline and confirm scheduled runs remain enabled:

```
cd /opt/rhai-upgrade-helpers/ai_pipelines
./post_upgrade_check.sh
```

**Llama Stack.** Recreate fresh 3.x-shaped `LlamaStackDistribution` CRs (deleted in Phase 5.4), using the Phase 5.4 archive only as *reference* — the SQLite data cannot be imported. 3.x requires PostgreSQL 14+, an explicitly enabled embedding provider, the `Vector_IO` API (VectorDB removed), `llama-stack-client` 0.4.x, and `config.yaml` (formerly `run.yaml`). See [Deploying a Llama Stack server](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/working_with_llama_stack/deploying-llama-stack-server_rag).

**Kubeflow Training Operator.** Confirm running PyTorchJobs match the Phase 5.5 list, and verify new jobs can be created:

```
oc get pytorchjobs -A
/opt/rhai-upgrade-helpers/kubeflow-trainer/kubeflow-trainer-verification.sh    # ~7 min if the image isn't cached
```

Expect `Kubeflow Training Operator verification completed successfully.` A PyTorchJob in a failed state usually means the job itself failed, not the upgrade — inspect it with:

```
oc describe pytorchjob <name> -n <ns>
```

## 8.8 Verify model serving

Confirm the controllers are up and every ISVC (and any LLMInferenceService) is on `RawDeployment` / `Ready=True`:

```
oc get pods -n redhat-ods-applications -l control-plane=kserve-controller-manager
oc get pods -n redhat-ods-applications -l control-plane=odh-model-controller
oc get isvc -A -o json | jq -r '["NAMESPACE","NAME","DEPLOYMENT_MODE","READY"], (.items[] | [.metadata.namespace, .metadata.name, .status.deploymentMode, (.status.conditions[] | select(.type=="Ready") | .status)]) | @tsv' | column -t
oc get llminferenceservices --all-namespaces
```

Model-serving troubleshooting matrix:

| Symptom | Cause | Resolution |
|---------|-------|-----------|
| `READY: True` but all calls return **HTTP 503** | A Serverless ISVC wasn't converted before upgrade | Convert to RawDeployment post-upgrade per [KB 7134025](https://access.redhat.com/articles/7134025) |
| Healthy ISVC but requests 503 with "Application Not Available" | A ModelMesh ISVC wasn't converted | Convert per [KB 7134025](https://access.redhat.com/articles/7134025) |
| `KnativeServing` still `Ready`, idle pods in `knative-serving` | Serverless Operator not removed | No functional impact; uninstall the operator and `oc delete namespace knative-serving` |
| Standalone Authorino still `Ready` | Authorino not removed | No impact for ISVCs (they use kube-rbac-proxy); **breaks LLMInferenceService** — uninstall and use RHCL |
| Gateway API resources don't work | OSSM v2 not removed | Migrate dependents to Service Mesh v3, then uninstall OSSM v2 |
| Dashboard shows runtimes **Outdated** | Runtime templates advanced | Redeploy workloads on the latest global serving runtime templates |

## 8.9 Final assessment

Re-run the full lint on the upgraded cluster and confirm zero critical/failed findings:

```
rhai-cli lint --target-version 3.3.5 | grep -E 'Total:|FAIL|PASS'
```

`Failed: 0` means the platform-side migration is clean. Warnings are acceptable.

## Troubleshooting

**A model returns `Ready=False` after upgrade.** Confirm 8.2 (ConfigMap restore) ran before model verification. If it persists, check the predictor pod's events and logs.

**The Gateway dashboard URL doesn't resolve.** On clusters with an SRE-managed admission webhook restricting NetworkPolicy creation in `openshift-*` namespaces, the GatewayConfig reconciler's NetworkPolicy POST is rejected — disable it:

```
oc patch gatewayconfig default-gateway --type=merge -p '{"spec":{"networkPolicy":{"ingress":{"enabled":false}}}}'
```

**`workbench-2.x-to-3.x-upgrade.sh list --all` reports `Failed: N`.** Inspect each one:

```
oc describe notebook <name> -n <ns>
```

The usual cause is a custom image that still embeds oauth-proxy and must be rebuilt.

---

# Phase 9 — Re-test the migrated workloads

> **Phase 9 of 10 · After upgrade** — Re-run the Phase 2 tests and diff against the baseline. **Next:** Phase 10 — Clean up.

Phase 8 confirmed the *platform* is healthy. This phase confirms the *workloads* still work for users, and — critically — lets you **diff against the Phase 2 baseline**. These are smoke tests: they answer "does this thing still serve a request?" Re-run the same probes you saved before the migration; the before/after pair is your evidence that nothing silently broke.

## 9.1 Inference-test each model

Re-run the Phase 2 inference probe (predictor pod state + an HTTP request to each externally reachable endpoint) and compare responses to the baseline. Note the endpoints are now Gateway URLs and pods may have rolled onto newer runtime images:

```
for isvc in $(oc get isvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
  NS="${isvc%/*}"; NAME="${isvc##*/}"
  URL=$(oc get isvc "$NAME" -n "$NS" -o jsonpath='{.status.url}')
  POD_STATE=$(oc get pods -n "$NS" -l serving.kserve.io/inferenceservice="$NAME" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
  echo "--- $isvc --- URL:$URL pod:${POD_STATE:-none}"
  [[ "$URL" != https://* ]] && { echo "  HTTP: skipped (cluster-internal)"; continue; }
  MODEL_ID=$(curl -sk --max-time 10 "${URL}/v1/models" 2>/dev/null | jq -r '.data[0].id // empty')
  if [ -n "$MODEL_ID" ]; then
    curl -sk --max-time 30 "${URL}/v1/completions" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL_ID\",\"prompt\":\"The capital of France is\",\"max_tokens\":8,\"temperature\":0}" | jq -r '.choices[0].text // "(error)"'
  fi
done

# Every ISVC Ready=True
oc get isvc -A -o json | jq -r '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length'
```

## 9.2 Reach each workbench through the Gateway

3.x workbenches sit behind the Gateway at `https://<gateway-host>/notebook/<ns>/<name>/`. A 2xx/3xx confirms the route + kube-rbac-proxy work:

```
GATEWAY_HOST=$(oc get gatewayconfig default-gateway -o jsonpath='{.spec.hostname}')
for nb in $(oc get notebook -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
  NS="${nb%/*}"; NAME="${nb##*/}"
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${GATEWAY_HOST}/notebook/${NS}/${NAME}/")
  echo "$nb -> HTTP $CODE"
done
```

## 9.3 Confirm the DSPA serves the pipelines API

```
NS=<dspa-namespace>; TOKEN=$(oc whoami -t)
DSPA_HOST=$(oc get route -n "$NS" -l app.kubernetes.io/name=data-science-pipelines-operator -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
curl -sk -H "Authorization: Bearer $TOKEN" "https://${DSPA_HOST}/apis/v2beta1/healthz" | jq .
oc get dspa -A -o json | jq -r '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length'
```

## 9.4 Confirm Ray clusters accept work

```
oc get raycluster -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,DESIRED:.spec.workerGroupSpecs[0].replicas,AVAILABLE:.status.availableWorkerReplicas,STATUS:.status.state'
```

Each cluster should show `STATUS=ready` with `AVAILABLE` matching `DESIRED`. The before/after archive pair (Phase 2 vs Phase 9) is your proof the migration didn't break anything.

## Troubleshooting

- **LLM inference returns 502/503** — give the predictor a minute; the 3.x controller may still be rolling it onto the newer runtime image. Re-run after 60s.
- **A workbench URL returns 404** — the Gateway HTTPRoute hasn't propagated; wait ~2 min. If it persists, confirm the Notebook CR was patched (8.3).
- **DSPA endpoint 404** — the pipeline route path can vary; find it with:

  ```
  oc get httproute -A -l app.kubernetes.io/instance=<dspa-name> -o yaml
  ```

- **A Ray cluster isn't `ready`** — re-run the migration helper for that cluster:

  ```
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py post-upgrade --namespace <ns>
  ```

---

# Phase 10 — Clean up

> **Phase 10 of 10 · Clean up** — Remove the temporary assessment pod and finish housekeeping. This is the final phase.

With the migration verified, remove the temporary assessment pod and its PVC:

```
oc delete statefulset rhai-cli -n rhai-migration
oc delete pvc backup-rhai-cli-0 -n rhai-migration
```

> **Copy your backups off the PVC first.** Deleting the PVC destroys everything under `/tmp/rhoai-upgrade-backup` (assessment reports, RayCluster CRs, TrustyAI metrics/data, inferenceservice-config backup, Llama Stack archives). If you haven't already `oc cp`'d them to your workstation, do it before deleting.

Post-migration housekeeping:

- Communicate the new **model endpoint URLs** and **dashboard URL** (Gateway API) to downstream consumers and users; the 2.x URLs no longer resolve.
- Update runbooks/documentation that reference the removed **Serverless** or **ModelMesh** deployment modes.
- If any 2.x serving operators (Serverless, Service Mesh 2, standalone Authorino) or the `knative-serving` namespace remain, remove them (see the 8.8 matrix).

---

# References

- [Red Hat OpenShift AI 3.3 documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3)
- [Introducing the Kubernetes Gateway API in RHOAI 3.x](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/managing_resources/introducing-kubernetes-gateway-api_resource-mgmt)
- [Converting ModelMesh and Serverless InferenceServices to RawDeployment (KB 7134025)](https://access.redhat.com/articles/7134025)
- [OpenShift Container Platform backup and restore](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/backup_and_restore/backup-restore-overview)
- [How to submit a Proactive Case (KB 5387111)](https://access.redhat.com/articles/5387111)
- [Resolving dashboard URL 404 errors after upgrade (KB 7137771)](https://access.redhat.com/solutions/7137771)
- [OSSM 3.x fails to deploy on a disconnected cluster (KB 7141146)](https://access.redhat.com/solutions/7141146)
- [rhoai/rhai-cli-rhel9 in the Red Hat Ecosystem Catalog](https://catalog.redhat.com/en/software/containers/rhoai/rhai-cli-rhel9/69a580e6a46d08df99bffe08)

---

*This guide is a task-ordered rewrite of the Red Hat OpenShift AI 2.25.4 → 3.3 migration documentation. For the authoritative, component-organized reference (including full disconnected-environment command listings and legal notices), see the official product documentation linked above.*
