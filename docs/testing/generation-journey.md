# Generation job service journey

`node scripts/tracer-cli.mjs app -- test services generation` runs the real local Worker through loopback HTTP with private synthetic identities, sessions, a team, project and job payloads. Its original chapter makes 34 requests covering creation/replay/conflict, viewer/outsider/other-owner permissions, job claim and idempotency, live-device fencing, completion/readback, failed-job recovery on a second device, cancellation and cursor pagination. Generation here coordinates client-side jobs; no image model or provider is called.

The isolated runner denies Worker outbound requests, requires zero attempts, disables telemetry, sanitizes its child environment, bounds requests/responses and per-request time, and owns a 90-second process group with cleanup. It does not claim an OS network sandbox. Provider authentication, actual generation, native app behavior and measured source coverage remain unverified.

Use the explicit reviewed local package selected with `SCRIV_TRACER_CLI` and `SCRIV_TRACER_RUNTIME`, following the [atomic runtime setup](atomic-batch-journey.md). The runtime and its complete local import graph are hash-pinned; missing setup fails rather than substituting a recorder.

`generation-steps.json` declares the 34 ordered named actions, concrete preconditions and assertion witnesses. The real harness executes 34 action callbacks and 34 assertion callbacks. Results are adapter-reported, not inferred source hits; reviewed manual associations remain separate from execution and measured coverage.

The appended [metadata and device recovery chapter](generation-recovery.md) adds 30 HTTP requests, for 64 total. It checks exact metadata refusals, 160-character progress, current-state replay after another device recovers, public logout and projected waiting with a still-future lease, explicit second-device recovery, and receipt/state preservation. The original 34-callback runtime report remains separate from this appended evidence.
