# Image evidence isolation scenario

`tests/e2e/image-evidence-isolation.mjs` checks the automation observer's fresh-run UUID, schema, empty synthetic job list, repeatability and rejection of caller-supplied paths/job IDs. It initiates no connection, authentication, provider turn or import. It requires the newly compiled observer; old output8 cannot run it.

Runtime validation is pending. This is new safety coverage for the CLI observation surface, not a replacement for any legacy image generation, artifact integrity, decode, attachment or rendered-preview assertion. The actual completed-job branch still requires an authorized real image workflow and separate verification. No legacy test is retired by this scenario.
