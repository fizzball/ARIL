# Routing & grading evals

Phase 2+ harness. Place golden prompts here:

```json
{
  "id": "coding-001",
  "prompt": "Fix this Swift concurrency bug…",
  "expected_primary": "coding",
  "expected_model_contains": "gpt-4"
}
```

In-app smoke: category prompts in the macOS client under Learning → **Run Selected Model Test** (Manual mode, Preferences → Models per category). [`auto_smoke.json`](auto_smoke.json) remains a reference list; full Auto vs Manual vs Judge bake-off is deferred.

Runners will land under `evals/runner/` once the preview pipeline leaves stub heuristics.
