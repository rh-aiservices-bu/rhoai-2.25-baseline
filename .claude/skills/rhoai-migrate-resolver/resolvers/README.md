# Pre-upgrade resolvers — rhai-cli output → resolver map

> For the **post-upgrade** chapter 4 resolvers, see [post-upgrade/README.md](post-upgrade/README.md).


The `rhai-cli lint --target-version 3.5` report has one row per check with columns:

```
STATUS | KIND | GROUP | CHECK | IMPACT | MESSAGE
```

> Column order changed in 3.5: **`KIND` now precedes `GROUP`** (the 3.3 output listed `GROUP | KIND`). The routing table below still matches on (KIND, CHECK), so the reorder is cosmetic for routing — but read the columns in the new order when eyeballing raw output.

Status icons: `✗` critical, `⚠` warning, `✓` info. Work `prohibited` → `critical` first, then `warning`. `info` rows confirm a prereq was met — skip.

## Running rhai-cli

If the user hasn't run the tool yet, the migration guide §1.3–1.4 covers setup. Short version:

```
# Deploy the rhai-cli pod (one-time)
oc new-project rhai-migration
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: rhai-cli-backup, namespace: rhai-migration }
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: 5Gi } }
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: rhai-cli, namespace: rhai-migration }
spec:
  serviceName: rhai-cli
  replicas: 1
  selector: { matchLabels: { app: rhai-cli } }
  template:
    metadata: { labels: { app: rhai-cli } }
    spec:
      containers:
        - name: rhai-cli
          image: registry.redhat.io/rhoai/rhai-cli-rhel9:v3.5.0
          command: ["sh","-c","sleep infinity"]
          volumeMounts:
            - { name: backup, mountPath: /tmp/rhoai-upgrade-backup }
      volumes:
        - name: backup
          persistentVolumeClaim: { claimName: rhai-cli-backup }
EOF

# Grant the pod's SA cluster-admin — rhai-cli needs to list OLM CSVs,
# DSC/DSCI, ISVCs, and operator CRDs cluster-wide. Without this, the
# lint fails with: clusterserviceversions.operators.coreos.com is
# forbidden: User "system:serviceaccount:rhai-migration:default" cannot
# list resource "clusterserviceversions" at the cluster scope
oc create clusterrolebinding rhai-cli-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=rhai-migration:default

# Confirm the binary version (should report: kubectl-odh version 1.26.4)
oc exec -n rhai-migration rhai-cli-0 -- /opt/rhai-cli/bin/rhai-cli version

# Run the lint
oc exec -n rhai-migration rhai-cli-0 -- /opt/rhai-cli/bin/rhai-cli lint --target-version 3.5

# Or capture as YAML to attach to a support case
oc exec -n rhai-migration rhai-cli-0 -- /opt/rhai-cli/bin/rhai-cli lint --target-version 3.5 --output yaml > rhai-cli-output.yaml
```

The CLI image is `registry.redhat.io/rhoai/rhai-cli-rhel9:v3.5.0` (pulls with the cluster's global pull secret; the binary is `kubectl-odh` version 1.26.4). `lint` exit codes:

- `0` — all checks passed.
- `1` — one or more `prohibited`/`critical` findings (expected on a real pre-upgrade cluster, **not** a tool error).
- `2` — warning-only findings (expected, not a tool error).

**Per-component work is now driven by `rhai-cli migrate` actions, not helper scripts.** The `/opt/rhai-upgrade-helpers/*.sh` directory no longer ships in 3.5. Backups, pre/post-upgrade checks, and conversions run as `rhai-cli migrate run|prepare|list --migration <name> --target-version 3.5.0` (with optional `--dry-run` / `--output-dir`). See [../reference/oc-patterns.md](../reference/oc-patterns.md) § *`rhai-cli migrate` actions* for the form, and each resolver for its specific `--migration <name>`. `lint` is pre-upgrade only — on a cluster already at 3.5 it no-ops (*"Current and target versions are the same (3.5), no checks will be executed."*); post-upgrade work uses the `migrate run` actions, which auto-detect the post-upgrade phase.

### Cleanup after migration

```
oc delete clusterrolebinding rhai-cli-admin
oc delete project rhai-migration
```

## Routing table

Match on (KIND, CHECK). If more than one row matches a resolver, walk through that resolver once.

| GROUP | KIND | CHECK (substring match) | Resolver |
| --- | --- | --- | --- |
| service | openshift | version-requirement | [ocp.md](ocp.md) |
| dependency | cert-manager | * | [cert-manager.md](cert-manager.md) |
| component | kueue | * | [kueue.md](kueue.md) |
| component | kserve | serverless-removal, serving-removal | [kserve.md](kserve.md) § *Disable Serverless mode* |
| component | modelmeshserving | removal | [kserve.md](kserve.md) § *Disable ModelMesh* |
| workload | kserve | impacted-workloads, isvc-*, servingruntime-* | [kserve.md](kserve.md) § *Convert InferenceServices* |
| dependency | servicemesh-operator-v2 | upgrade, uninstall | [kserve.md](kserve.md) § *Uninstall Service Mesh v2* |
| dependency | serverless-operator | uninstall | [kserve.md](kserve.md) § *Uninstall OpenShift Serverless* |
| dependency | authorino-operator | uninstall | [kserve.md](kserve.md) § *Uninstall standalone Authorino* |
| workload | notebook | image-version, custom-image, stopped | [workbenches.md](workbenches.md) |
| component | datasciencepipelines | * | [pipelines.md](pipelines.md) |
| component | ray | *, codeflare-removal | [ray.md](ray.md) |
| component | trustyai | * | [trustyai.md](trustyai.md) |
| workload | guardrails | * | [trustyai.md](trustyai.md) § *Guardrails* |
| workload | llamastack | * | [llama-stack.md](llama-stack.md) |
| workload | llminferenceservice | template-pinning, auth | [llm-isvc.md](llm-isvc.md) |

Anything not in the table: read the raw rhai-cli message and search the official RHOAI 2.25.10 (and later) → 3.5 migration guide for the matching §2.x section before answering. The migration guide is not committed to this repo — fall back to each resolver's inline quotes for authoritative wording.

## Priority order

When walking the user through results, sequence the resolvers so that dependencies resolve before dependents:

1. **backup.md** — verified backup is the **only** rollback for in-place migration. Walk this *before any mutating step*. Layers 1 (etcd) and 2 (OADP) must both be in place before resolvers 3 onward are touched. See the repo-level [BACKUP-RESTORE.md](../../../../BACKUP-RESTORE.md) for the full execution procedure.
2. **ocp.md** — must be on 4.19.9+ before anything else
3. **cert-manager.md** — installed early; required by Kueue/KServe/Ray in 3.x
4. **kueue.md** — Managed → Removed (architectural-changes.md § Kueue Transition: leaving as Managed causes unrecoverable cluster instability)
5. **workbenches.md** — rebuild custom images, bump code-server/RStudio, then stop all
6. **trustyai.md** + **llama-stack.md** + **ray.md** + **pipelines.md** — backups / pre-upgrade checks (order doesn't matter)
7. **kserve.md** — the biggest block: convert ISVCs, then flip DSC/DSCI, then uninstall the three operators
8. **llm-isvc.md** — pin templates last, just before the upgrade

Re-run `rhai-cli lint` between major phases — some checks only activate once prior items are done (e.g. the DSCI `serviceMesh` check doesn't fire until Serverless ISVCs are gone).

## After the resolvers — what the actual upgrade looks like

The resolvers stop at "pre-upgrade clean." The upgrade itself is two steps in the migration guide, but with a wrinkle worth knowing in advance:

1. **Channel switch.** `oc -n redhat-ods-operator patch subscription rhods-operator --type=merge -p '{"spec":{"channel":"support-required-upgrade-3.5"}}'` — the channel name is intentionally verbose to prevent accidental triggers and is versioned in 3.5 (the unversioned `support-required-upgrade` is the 2.25→3.3 path only; only `support-required-upgrade-3.5` provides the cross-major 2.25→3.5 path). Confirm the current channel first (`oc -n redhat-ods-operator get subscription rhods-operator -o jsonpath='{.spec.channel}'`); typical pre-state is `stable-2.25`.

2. **OLM walks the upgrade graph one CSV at a time — not in a single jump.** Even though `support-required-upgrade-3.5`'s `currentCSV` is `rhods-operator.3.5.0`, OLM walks the `replaces` chain. From a cluster on `2.25.10` you'll see the intermediate z-stream InstallPlans in sequence before the final `→ 3.5.0` step. Each requires manual approval because the migration channel uses `installPlanApproval: Manual`. Approve the first, wait for `Succeeded`, then the next appears.

   ```
   # Approve whichever InstallPlan is currently unapproved
   IP=$(oc -n redhat-ods-operator get installplan -o json | jq -r '.items[] | select(.spec.approved==false) | .metadata.name' | head -1)
   oc -n redhat-ods-operator patch installplan "$IP" --type=merge -p '{"spec":{"approved":true}}'
   ```

3. **HardwareProfiles auto-migrate** from `dashboard.opendatahub.io/v1alpha1` to `infrastructure.opendatahub.io` with **renamed objects** (e.g., `large-notebooks-17kpw` → `containersize-large-notebooks`) — any user automation referencing the old names breaks here. The lint's `hardwareprofile-migration` advisory is the warning sign before the upgrade.

   > **DSC schema rename — now shipped and automatic in 3.5.** The rename that 3.3.x only warned about is live in 3.5: on the first post-upgrade operator startup the DSC is converted v1→v2 via the conversion webhook — `.spec.components.datasciencepipelines` → `.spec.components.aipipelines`, and `modelmeshserving` and `codeflare` are removed. This is handled automatically by the operator; you do **not** patch these field names by hand. Pre-upgrade you still write the *v1* field names (`datasciencepipelines`, `modelmeshserving`, `serviceMesh`) — that's intentional; the operator converts them after the upgrade. Automation that references the old component paths should be updated to `aipipelines` only after the cluster is on 3.5.

4. **Switch off the migration channel once you're on 3.5.0.** `support-required-upgrade-3.5` is a one-shot trigger channel — it does not advance to later 3.5.x patch releases. Leaving the subscription there means no ongoing z-stream updates. After the upgrade completes, move to a going-forward 3.x channel so the cluster receives patches:

   ```
   oc patch subscription rhods-operator -n redhat-ods-operator --type=merge \
     -p '{"spec":{"channel":"stable-3.5"}}'
   ```

   Pick `stable-3.5` (stays on the 3.5 z-stream) rather than `stable-3.x` (would eventually offer a later minor upgrade); `eus-3.5` is also available. See [post-upgrade/operator.md](post-upgrade/operator.md) § *Switch the subscription channel off the migration channel* for the full step + verification.

After step 3 reports `phase=Succeeded` + DSC `Ready`, run [post-upgrade/workbenches.md](post-upgrade/workbenches.md) to patch workbenches off the 2.x oauth-proxy auth model, and do the channel switch in step 4. The rest of the post-upgrade resolvers are component-specific (see [post-upgrade/README.md](post-upgrade/README.md)).
