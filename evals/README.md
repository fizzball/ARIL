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

In-app smoke: [`auto_smoke.json`](auto_smoke.json) (~8 prompts) is mirrored by Learning → **Run Auto eval** in the macOS client (Auto mode only; full Auto vs Manual vs Judge bake-off is deferred).

Runners will land under `evals/runner/` once the preview pipeline leaves stub heuristics.
