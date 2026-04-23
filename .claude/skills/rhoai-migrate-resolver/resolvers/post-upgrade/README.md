# Post-upgrade resolvers

After the RHOAI operator CSV reaches `rhods-operator.3.3.2` and the old 2.x CSV is gone, walk through these component tasks to finalize the cluster. The order matters only for a couple of steps (workbenches before Ray); otherwise run them as needed.

## Suggested order

1. **[operator.md](operator.md)** — platform health: DSC/DSCI Ready, Gateway ready, Kueue recovery, disconnected-OSSM3 troubleshooting.
2. **[model-serving.md](model-serving.md)** — restore `managed=true` on `inferenceservice-config`, verify KServe + ODH Model Controller, troubleshoot any leftover 2.x operators. Do this early — many other components depend on KServe.
3. **[workbenches.md](workbenches.md)** — patch stopped workbenches first (`workbench-2.x-to-3.x-upgrade.sh`). Blocks the Ray resolver.
4. **[ray.md](ray.md)** — run the Ray cluster migration script. Requires workbenches first.
5. **[registry-catalog.md](registry-catalog.md)** — verify Model Registry + AI Hub Catalog pods, tell users the dashboard nav moved.
6. **[feast.md](feast.md)** — Feature Store verification (skip if unused).
7. **[llama-stack.md](llama-stack.md)** — recreate LSDs from pre-upgrade archive (data was lost).
8. **[pipelines.md](pipelines.md)** — admin runs `post_upgrade_check.sh`, users validate pipelines.
9. **[trustyai.md](trustyai.md)** — check backups, fix Guardrails, restore data, handle GPU deadlock.
10. **[kfto.md](kfto.md)** — verify PyTorchJobs survived.

## Driving the skill

Use the top-level [../../scripts/post-upgrade-validate.sh](../../scripts/post-upgrade-validate.sh) — it produces one PASS / WARN / FAIL line per check, each prefixed with a component label in brackets (`[operator]`, `[model-serving]`, etc.). Any FAIL maps to the corresponding resolver file in this directory. Walk the user through it, then have them re-run `post-upgrade-validate.sh` to confirm.

## Map from validator label → resolver

| Validator label prefix | Resolver | Migration-guide citation |
| --- | --- | --- |
| `[operator]` | [operator.md](operator.md) | §4.1 |
| `[registry]` | [registry-catalog.md](registry-catalog.md) | §4.2 |
| `[feast]` | [feast.md](feast.md) | §4.3 |
| `[pipelines]` | [pipelines.md](pipelines.md) | §4.5 |
| `[trustyai]` | [trustyai.md](trustyai.md) | §4.6 |
| `[workbenches]` | [workbenches.md](workbenches.md) | §4.7 |
| `[ray]` | [ray.md](ray.md) | §4.8 |
| `[model-serving]` | [model-serving.md](model-serving.md) | §4.9 |
| `[kfto]` | [kfto.md](kfto.md) | §4.10 |

§N.N numbers are included only as pointers to the migration guide's text — they are not primary labels. Use the component name in conversation.
