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

Anything not in the table: read the raw rhai-cli message and search [ignore.md](../../../../ignore.md) for the matching §2.x section before answering.

## Priority order

When walking the user through results, sequence the resolvers so that dependencies resolve before dependents:

1. **ocp.md** — must be on 4.19.9+ before anything else
2. **cert-manager.md** — installed early; required by Kueue/KServe/Ray in 3.x
3. **kueue.md** — Managed → Removed (architectural-changes.md § Kueue Transition: leaving as Managed causes unrecoverable cluster instability)
4. **workbenches.md** — rebuild custom images, bump code-server/RStudio, then stop all
5. **trustyai.md** + **llama-stack.md** + **ray.md** + **pipelines.md** — backups / pre-upgrade checks (order doesn't matter)
6. **kserve.md** — the biggest block: convert ISVCs, then flip DSC/DSCI, then uninstall the three operators
7. **llm-isvc.md** — pin templates last, just before the upgrade

Re-run `rhai-cli lint` between major phases — some checks only activate once prior items are done (e.g. the DSCI `serviceMesh` check doesn't fire until Serverless ISVCs are gone).
