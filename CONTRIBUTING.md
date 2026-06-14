# Contributing

This is the runner-only OSS release of MyPCBench. Keep changes scoped to the
harness, tasks, docs, scripts, and persona metadata.

- `agent-harness/` — runner, environment wrapper, agents, rubric judge.
- `tasks/final/` — canonical 184-task set and rubrics (see its README).
- `personas/` — persona metadata read by the harness.
- `docs/` — run guides (QEMU-direct and Docker).

Basic checks before sending a change:

```bash
bash -n scripts/*.sh
python3 -m py_compile $(git ls-files '*.py')
PYTHONPATH=agent-harness python3 agent-harness/run_mypcbench.py --help >/dev/null
git diff --check
```
