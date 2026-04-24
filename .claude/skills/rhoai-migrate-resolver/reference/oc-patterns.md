# `oc` command conventions

Load this file with `Read` before emitting any `oc` command block for the user. These conventions prevent the most common formatting mistakes observed while running this skill against real clusters. Break a rule only with a specific reason.

---

## 1. Resource/name form — never double-specify the kind

`oc get <kind> -o name` returns `<fully.qualified.kind>/<name>`. Passing that output **and** the kind again to `oc patch`/`oc delete`/`oc describe` fails with:

```
error: there is no need to specify a resource type as a separate argument when passing arguments in resource/name form
```

**Wrong:**

```sh
oc patch dsc $(oc get dsc -o name | head -n1) --type=merge -p '{"spec":{"components":{"kueue":{"managementState":"Removed"}}}}'
```

**Right:**

```sh
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{"spec":{"components":{"kueue":{"managementState":"Removed"}}}}'
```

Same for `oc delete`, `oc describe`, `oc annotate`, `oc label`:

```sh
oc delete $(oc get isvc my-isvc -n my-ns -o name) -n my-ns
oc annotate $(oc get cm inferenceservice-config -n redhat-ods-applications -o name) -n redhat-ods-applications opendatahub.io/managed=true --overwrite
```

Also applies when iterating:

```sh
for r in $(oc get notebooks -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
  ns="${r%%/*}"; name="${r##*/}"
  oc annotate notebook "$name" -n "$ns" kubeflow-resource-stopped=true --overwrite
done
```

(Here we're *not* using `-o name`, so `notebook` as a separate arg is correct.)

## 2. `oc patch` — pick the right type, quote the payload safely

Three patch types; default is `strategic` which works for core k8s objects but often fails on CRDs. **Default to `--type=merge` for CRD edits; use `--type=json` for array operations.**

```sh
# Scalar / nested-object set — merge patch
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": { "components": { "kserve": { "serving": { "managementState": "Removed" } } } }
}'

# Replace one element inside an array — JSON patch
oc patch notebook jupyter-2025-1 -n workbenches-regular --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/jupyter-datascience-cpu-py312-ubi9:2025.2"}
]'
```

**Quoting rules:**

- Always wrap the `-p` payload in **single quotes** so the shell doesn't interpolate `$` or backticks.
- Multi-line JSON inside single quotes is fine — `oc` parses it as one arg.
- If a value needs shell interpolation, build the JSON string first with `$(…)` then pass it:
  ```sh
  PAYLOAD=$(printf '{"metadata":{"labels":{"app":"%s"}}}' "$APP")
  oc patch ... --type=merge -p "$PAYLOAD"
  ```

## 3. Idempotency — prefer `oc apply` over `oc create`

- `oc create -f foo.yaml` fails on `AlreadyExists`. Do not use in resolver output.
- `oc apply -f foo.yaml` creates or patches. Safe to re-run.
- For one-off creates where you want failure-on-exists (rare), say so explicitly.

For annotations/labels always add `--overwrite`:

```sh
oc annotate cm inferenceservice-config -n redhat-ods-applications \
  opendatahub.io/managed=true --overwrite
```

Without `--overwrite`, modifying an existing annotation fails with `already has a value`.

For deletes, use `--ignore-not-found` to keep cleanup blocks idempotent:

```sh
oc delete knativeserving knative-serving -n knative-serving --ignore-not-found
```

## 4. Namespace — always explicit `-n <ns>` in emitted commands

Never rely on the user's current context (`oc project`). Every resolver command must specify `-n <ns>`. Exceptions: cluster-scoped kinds (DSC, DSCI, CSV subset, nodes, clusterpolicy, clusterrolebinding, namespace, gatewayconfig cluster-scoped instances, etc.).

## 5. `jsonpath` quoting, escapes, ranges

- Always single-quote the jsonpath expression to keep `$` and `.` literal for the shell.
- Label keys with dots need `\.` inside the path:
  ```sh
  oc get nodes -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}'
  ```
- Multi-row output: use `{range .items[*]}…{end}` + explicit `{"\n"}`:
  ```sh
  oc get isvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.status.deploymentMode}{"\n"}{end}'
  ```
- Custom columns for tabular output:
  ```sh
  oc get isvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,MODE:.status.deploymentMode,READY:.status.conditions[?(@.type=="Ready")].status'
  ```

## 6. `oc exec` into helper pods

Always put `--` between the pod and the command. For anything non-trivial use `bash -c '<script>'`:

```sh
oc exec -n rhai-migration rhai-cli-0 -- /opt/rhai-cli/bin/rhai-cli lint --target-version 3.3.2

oc exec -n rhai-migration rhai-cli-0 -- bash -c '
  cd /opt/rhai-upgrade-helpers/workbenches && \
  ./workbench-2.x-to-3.x-upgrade.sh patch --only-stopped --with-cleanup -y
'
```

For helpers that expect a TTY prompt, pass `-y` / `--yes` or the tool will exit immediately since `oc exec` without `-it` is non-interactive.

`oc cp` is the read-only equivalent for extracting files:

```sh
oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup ./local-backup
```

## 7. Waiting on async status

Pick the right wait primitive:

| Need | Command |
| --- | --- |
| Deployment rollout | `oc rollout status deployment/<name> -n <ns> --timeout=10m` |
| CRD condition | `oc wait --for=condition=<Type>=<True|False> <kind>/<name> -n <ns> --timeout=5m` |
| Arbitrary jsonpath value | `oc wait --for=jsonpath='{.status.phase}'=Ready <kind>/<name> -n <ns> --timeout=10m` |
| CSV `phase=Succeeded` | poll in a loop (CSVs don't expose a matching condition in all OLM versions) |

For CSVs and other resources without a convenient condition, poll with a bash loop:

```sh
deadline=$(( $(date +%s) + 900 ))
while (( $(date +%s) < deadline )); do
  phase=$(oc get csv -n redhat-ods-operator rhods-operator.2.25.4 -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$phase" == "Succeeded" ]] && break
  sleep 10
done
```

## 8. Heredoc applies

Prefer `oc apply -f -` with a here-doc over shelling out `echo`. Use `<<'EOF'` (quoted) to prevent variable expansion, `<<EOF` (unquoted) to allow it:

```sh
# Static YAML — quote the delimiter so $VARS are literal
oc apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: dummy
  namespace: test
type: Opaque
stringData:
  key: value
EOF

# YAML with variable expansion — do NOT quote the delimiter
NS=$1
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
EOF
```

If the YAML contains literal `$` (e.g. shell-syntax examples, templating), quote the delimiter.

## 9. Backup-and-recreate (needed when a webhook blocks in-place edits)

Some CRDs (notably KServe `InferenceService`) reject `deploymentMode` changes via `oc patch`. The pattern is to export, strip server-managed fields, edit, delete, and re-apply:

```sh
NS=<namespace>; NAME=<isvc>

oc get isvc "$NAME" -n "$NS" -o yaml \
  | yq eval 'del(
      .metadata.resourceVersion,
      .metadata.uid,
      .metadata.creationTimestamp,
      .metadata.generation,
      .metadata.managedFields,
      .metadata.selfLink,
      .status
    )' - \
  > "/tmp/isvc-${NS}-${NAME}.yaml"

# edit the file (change annotation, field, etc.)
yq -i '.metadata.annotations."serving.kserve.io/deploymentMode" = "RawDeployment"' \
  "/tmp/isvc-${NS}-${NAME}.yaml"

oc delete isvc "$NAME" -n "$NS"
oc apply -f "/tmp/isvc-${NS}-${NAME}.yaml"
```

Always strip `status`, `resourceVersion`, `uid`, `creationTimestamp`, `generation`, `managedFields`, `selfLink` — leaving any of these can cause `oc apply` to fail or cargo-cult a stale generation.

## 10. `-A` vs `--all-namespaces`, selectors, label equality

- `-A` is the short flag for `--all-namespaces`. Use it.
- Label selectors: `=` for equality (`-l app=foo`), `==` is also accepted but `=` is the convention. No spaces around `=`.
- Multi-label AND: `-l app=foo,env=prod`.
- Multi-label OR: not supported; use `in`: `-l 'env in (prod,stage)'`.
- Field selectors for pods: `--field-selector=status.phase=Running`.

## 11. `oc get csv -A | grep …` with `set -o pipefail`

`grep -q` exits on first match, so `oc` gets SIGPIPE and the pipeline exits 141. Under `set -o pipefail` the whole `if` goes false.

- **Scripts:** either omit `pipefail` or use `grep -c` (reads all input) and compare the count.
- **User-facing commands:** recommend `grep` without `-q` when piping from a streaming `oc` command, or pipe through `head -n1` first.

## 12. Common RHOAI kind names (long form)

Because the CRDs use the `<group>.<group>.<root>` doubled pattern, `-o name` emits the long form:

| Kind in YAML | `-o name` output |
| --- | --- |
| DataScienceCluster | `datasciencecluster.datasciencecluster.opendatahub.io/<name>` |
| DSCInitialization | `dscinitialization.dscinitialization.opendatahub.io/<name>` |
| DataSciencePipelinesApplication | `datasciencepipelinesapplication.datasciencepipelinesapplications.opendatahub.io/<name>` |

Use the short kind (`dsc`, `dsci`, `dspa`) for direct args. Use `$(oc get <short> -o name)` (without re-specifying the kind) when composing.

## 13. `oc api-resources` / `oc explain` — use when uncertain

If a field/schema might have changed between versions, tell the user to run `oc explain <kind>.<field>` before patching:

```sh
oc explain inferenceservice.spec.predictor
oc explain guardrailsorchestrator.spec.otelExporter
```

This is especially relevant across the 2.25 → 3.x split where fields like `otelExporter.otlpEndpoint` (2.x) became `otlpMetricsEndpoint`/`otlpTracesEndpoint` (3.x).

## 14. OpenShift-specific commands (not in `kubectl`)

`oc` is a superset of `kubectl` with OpenShift-specific verbs. Use these where they give you something `kubectl` can't.

### `oc new-project <name>` — creates Project + Namespace + sets current context

```sh
oc new-project rhai-migration
```

This does **three** things in one call:

1. Creates a `Project` (OpenShift kind) — not just a Namespace.
2. Creates the backing Namespace.
3. **Switches your current context** to that project, same as `oc project rhai-migration` after.

Gotchas:

- Because it switches context, **do not use in automation** that shouldn't mutate the operator's shell. Use `oc create namespace <name>` instead if you only want the namespace without the context switch.
- Fails with `projectrequests.project.openshift.io is forbidden` if the user lacks self-provisioner; fall back to `oc create namespace`.
- Idempotency: `oc new-project` fails if the Project already exists. Use:
  ```sh
  oc get project rhai-migration >/dev/null 2>&1 || oc new-project rhai-migration
  ```
  Or bypass entirely:
  ```sh
  oc create namespace rhai-migration --dry-run=client -o yaml | oc apply -f -
  ```

### `oc project [<name>]` — print / switch context

```sh
oc project                     # print current project
oc project redhat-ods-operator # switch to that project
```

For automation, **prefer `-n <ns>` on every command** over `oc project`. Leaving a user's context changed after a script runs is a common bug.

### `oc adm` — admin-only operations

| Command | What it does |
| --- | --- |
| `oc adm policy add-scc-to-user <scc> -z <sa> -n <ns>` | Bind a ServiceAccount to a SecurityContextConstraint (e.g., `anyuid`). `-z` = ServiceAccount, `-n` = namespace. |
| `oc adm policy add-scc-to-group <scc> <group>` | Same, for a group. |
| `oc adm cordon <node>` / `oc adm uncordon <node>` | Mark a node un/schedulable. |
| `oc adm drain <node> --ignore-daemonsets --delete-emptydir-data` | Evict pods off a node (for node replacement / upgrade). |
| `oc adm upgrade [--to=<version>]` | OCP cluster upgrade. |
| `oc adm upgrade channel <channel>` | Change the OCP upgrade channel (e.g., `stable-4.19`). |
| `oc adm must-gather --image=<image> --dest-dir=<path>` | Collect diagnostic data for a support case. |
| `oc adm top node` / `oc adm top pod -A` | Resource usage (needs metrics-server). |

For SCC bindings, the RBAC-based form is preferred for GitOps (see [../resolvers/workbenches.md](../resolvers/workbenches.md) for the RoleBinding-to-`system:openshift:scc:anyuid` pattern). `oc adm policy add-scc-to-user` is the imperative equivalent.

### `oc rsh <pod>` vs `oc exec <pod> -- <cmd>`

- `oc rsh pod-name` — interactive shell into a pod (assumes `/bin/sh` exists). Roughly equivalent to `oc exec -it pod-name -- /bin/sh`.
- `oc exec` — one-shot command execution. Use this in automation and in skill-emitted commands. `oc rsh` is for the user's interactive troubleshooting.

### `oc debug node/<node>` — chroot into the host filesystem

```sh
oc debug node/ip-10-0-1-34.us-east-2.compute.internal
# inside the debug pod:
chroot /host
# now running on the node itself (as root)
```

Use for: inspecting kernel modules (GPU driver debug), checking `/var/log/containers`, reading `crio` state. Requires cluster-admin. Skill resolvers should mention this when driver / kernel issues are suspected.

### `oc port-forward <resource> <local:remote>`

```sh
oc port-forward -n redhat-ods-applications svc/trustyai-service 8080:8080
```

Always specify `-n`. The process holds the port until killed — remind the user to background it (`&`) and kill it (`kill %1`) in a script, or run in a separate terminal interactively.

### `oc logs` — useful flags

```sh
oc logs -n <ns> <pod> -c <container>        # specific container in multi-container pod
oc logs -n <ns> <pod> --previous            # previous terminated container (crash loop)
oc logs -n <ns> -l <selector> --tail=50     # logs across every pod matching the selector
oc logs -n <ns> deployment/<name>           # one replica from a Deployment
```

### `oc expose` / routes vs Gateway API

- **2.x clusters:** `oc expose svc/<svc>` creates a Route. Migration resolvers may still reference Routes in the pre-upgrade phase.
- **3.x clusters:** Route → Gateway API. `oc expose` still works for ad-hoc Routes, but anything RHOAI-managed is now under `gatewayconfigs`/`httproutes`. When emitting commands for post-upgrade, prefer:
  ```sh
  oc get gatewayconfigs -A
  oc get httproute -A
  ```

### `oc get-token` / `oc whoami -t`

```sh
TOKEN=$(oc whoami -t)
curl -sk -H "Authorization: Bearer $TOKEN" https://<route>/healthz
```

Useful for the TrustyAI metric replay and port-forward + curl patterns in the TrustyAI resolver. The token is the caller's bearer token, valid for the OAuth session lifetime.

### `oc login` — script-safe form

```sh
oc login --server=https://api.cluster.example.com:6443 --token=<token>
# or
oc login --server=... -u <user> -p <pass>    # avoid in shared shells — hits history
```

Never emit a command that writes a real bearer token inline. Use env vars:

```sh
oc login --server=$OCP_API --token=$OCP_TOKEN
```

### `oc explain` — schema lookup on the live cluster

Already covered in §13 above. Worth repeating: when in doubt about a field, `oc explain` tells you what the *current* cluster accepts. This beats guessing.

---

## 15. Where to copy-paste commands from

- Resolvers (pre- and post-upgrade) are the canonical source. When you emit a command, prefer one that appears verbatim in the matching resolver.
- If a resolver's command is subtly wrong for the user's cluster (e.g., different namespace, different ISVC name), edit the command inline and note what changed — **do not silently substitute unrelated changes**.
