# Reusable scenario steps

These catalogs expose reviewed actions, required fixture state, expected results and source/assertion snippets without reconstructing every association from a test script. They are declared navigation, separate from measured coverage and from recorded callback outcomes.

- `atomic-batch-steps.json`: 29 ordered steps with real HTTP action/assertion callbacks. The catalog and runtime are explicitly integrated into the isolated atomic service journey.
- `discussions-assets-steps.json`: five phases, 40 ordered actions, 24 assertion witnesses and 31 pre-existing source associations. This uninstrumented journey is declared navigation only; conversion adds no mapped lines or runtime claim.
- `billing-steps.json`: 27 real HTTP action/assertion callbacks with a strictly local synthetic provider fixture.
- `generation-steps.json`: 34 real HTTP action/assertion callbacks for local job coordination; no provider execution.
- `tooling-service-steps.json`: grouped existing CLI tooling assertions and mappings, deliberately relocated after the fixed service catalog expanded.

Use the reviewed local Tracer CLI selected through `SCRIV_TRACER_CLI`. Atomic runtime setup is described in [the service journey](atomic-batch-journey.md). Neither the local package bytes nor a hardcoded machine path are vendored here; a missing runtime is an explicit setup failure.

```sh
node scripts/tracer-cli.mjs scenario check --file docs/testing/atomic-batch-steps.json --json
node scripts/tracer-cli.mjs scenario report --file docs/testing/atomic-batch-steps.json --scenario atomic-batch-structural-edit --json
node scripts/tracer-cli.mjs app -- test services atomic-batch
```

`scenario prepare`, `check`, `report` and `packet` do not run an application or approve a mapping. One integration owner reviews changed source/assertion relationships and composition assumptions before hash-guarded `scenario link`. Full declared action identity is retained; step slicing and renaming cannot create extra traces. Runtime callback results are explicitly adapter-reported and do not infer executed source lines.

New app catalogs must reconcile the complete ordered commands and fixture preconditions, including polling, read retries and conditional scrolling. An abbreviated old action summary is not enough for new scenario integration. The current timing and character/generation candidates were held out for that reason; two explicitly inaccurate old target descriptions were removed rather than replaced with another summary. Native execution and measured-coverage gaps remain unchanged.
