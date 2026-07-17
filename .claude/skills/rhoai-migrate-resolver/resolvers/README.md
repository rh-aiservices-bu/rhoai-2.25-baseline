# Pre-upgrade resolvers — rhai-cli output → resolver map

> For the **post-upgrade** chapter 4 resolvers, see [post-upgrade/README.md](post-upgrade/README.md).


The `rhai-cli lint --target-version 3.3.2` report has one row per check with columns:

```
STATUS | GROUP | KIND | CHECK | IMPACT | MESSAGE
```

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
          image: registry.redhat.io/rhoai/rhai-cli-rhel9:v3.3.2
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

# Run the lint
oc exec -n rhai-migration rhai-cli-0 -- /opt/rhai-cli/bin/rhai-cli lint --target-version 3.3.2

# Or capture as YAML to attach to a support case
oc exec -n rhai-migration rhai-cli-0 -- /opt/rhai-cli/bin/rhai-cli lint --target-version 3.3.2 --output yaml > rhai-cli-output.yaml
```

### Cleanup after migration

```
oc delete clusterrolebinding rhai-cli-admin
oc delete project rhai-migration
```

## Routing table

**Primary path: run the router, don't match by hand.** Save the rhai-cli report to a file and
run `bash ../scripts/route.sh <report>` — it prints the priority-ordered resolver list for
you. The table below is the fallback the script is built from; use it only if the script can't
recognize the report format.

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
| workload | llamastackdistribution | * | [llama-stack.md](llama-stack.md) |
| workload | llminferenceservice | template-pinning, auth | [llm-isvc.md](llm-isvc.md) |

Anything not in the table: read the raw rhai-cli message and search the official RHOAI 2.25.4 → 3.3.2 migration guide for the matching §2.x section before answering. The migration guide is not committed to this repo — fall back to each resolver's inline quotes for authoritative wording.

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

1. **Channel switch.** `oc -n redhat-ods-operator patch subscription rhods-operator --type=merge -p '{"spec":{"channel":"support-required-upgrade"}}'` — the channel name is intentionally verbose to prevent accidental triggers and is the same on every 2.25.x → 3.3.x migration. Confirm the current channel first (`oc -n redhat-ods-operator get subscription rhods-operator -o jsonpath='{.spec.channel}'`); typical pre-state is `stable-2.25`.

2. **OLM walks the upgrade graph one CSV at a time — not in a single jump.** Even though `support-required-upgrade`'s `currentCSV` is `rhods-operator.3.3.2`, OLM walks the `replaces` chain. From a cluster on `2.25.4` you'll see two unapproved InstallPlans in sequence: first `2.25.4 → 2.25.6`, then `2.25.6 → 3.3.2`. Both require manual approval because the migration channel uses `installPlanApproval: Manual`. Approve the first, wait for `Succeeded`, then the second appears.

   ```
   # Approve whichever InstallPlan is currently unapproved
   IP=$(oc -n redhat-ods-operator get installplan -o json | jq -r '.items[] | select(.spec.approved==false) | .metadata.name' | head -1)
   oc -n redhat-ods-operator patch installplan "$IP" --type=merge -p '{"spec":{"approved":true}}'
   ```

3. **HardwareProfiles auto-migrate** from `dashboard.opendatahub.io/v1alpha1` to `infrastructure.opendatahub.io` with **renamed objects** (e.g., `large-notebooks-17kpw` → `containersize-large-notebooks`) — any user automation referencing the old names breaks here. The lint's `hardwareprofile-migration` advisory is the warning sign before the upgrade.

   > **DSC schema rename — verified NOT shipped in 3.3.3.** Architectural notes (and the rhai-cli `datasciencepipelines / renaming` warning) describe a future rename of `.spec.components.datasciencepipelines` → `.spec.components.aipipelines` plus new `trainer` and `mlflowoperator` DSC fields. On a real 3.3.3 cluster `oc explain dsc.spec.components.aipipelines` returns `field "aipipelines" does not exist` and `datasciencepipelines` is still the live component path. The lint's warning is *forward-looking* — it tells you the rename is coming, not that it has happened. Earlier revisions of this README claimed the rename was active in 3.3.2; that was wrong. Do not direct automation owners to flip their DSC field names until the rename actually ships.

4. **Switch off the migration channel once you're on 3.3.2.** `support-required-upgrade` is a one-shot trigger channel — it does not advance to later 3.3.x patch releases. Leaving the subscription there means no ongoing z-stream updates. After the upgrade completes, move to the stable 3.3 channel so the cluster receives 3.3.x patches:

   ```
   oc patch subscription rhods-operator -n redhat-ods-operator --type=merge \
     -p '{"spec":{"channel":"stable-3.3"}}'
   ```

   Pick `stable-3.3` (stays on the 3.3 z-stream) rather than `stable-3.x` (would eventually offer a 3.4 minor upgrade). See [post-upgrade/operator.md](post-upgrade/operator.md) § *Switch the subscription channel off the migration channel* for the full step + verification.

After step 3 reports `phase=Succeeded` + DSC `Ready`, run [post-upgrade/workbenches.md](post-upgrade/workbenches.md) to patch workbenches off the 2.x oauth-proxy auth model, and do the channel switch in step 4. The rest of the post-upgrade resolvers are component-specific (see [post-upgrade/README.md](post-upgrade/README.md)).
