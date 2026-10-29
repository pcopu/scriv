# Codex integration contract

Scriv runs the user's installed Codex app-server locally. The managed connection starts `codex app-server` over newline-delimited JSON on standard input/output. An optional connection attaches to a loopback WebSocket server. Scriv creates ordinary Codex threads and turns, then imports a real generated image into the project. ChatGPT authentication stays in the local Codex runtime and is separate from the Scriv cloud account.

## Verified runtime and evidence

On **2026-10-29**, the integration was checked against **`codex-cli 0.165.0`**, downloaded from the official package `@openai/codex@0.165.0-linux-x64`. Its own `app-server generate-json-schema` command produced the schemas used for validation. This audit ran no account login, model turn, image generation, or paid request.

The result was **18 passing checks**: 15 valid request/response fixtures and three invalid regression fixtures that the schema correctly rejected. The exact evidence is committed here:

- [Request and response fixtures](../tests/fixtures/codex-0.165.0.json)
- [Recorded verification result](verification/codex-0.165.0.json)
- [Reproducible validator](../scripts/check-codex-contract.py)
- [Native integration](../apps/mac/Sources/ScrivApp/Services/CodexController.swift)

The executable and full generated schema bundle are intentionally external build inputs. Generate schemas from the precise runtime version being evaluated. The fixtures describe the payload shapes used by Scriv; they are not a capture of an authenticated session.

## Wire contracts

| Operation | Verified shape or behavior |
| --- | --- |
| Initialization | `initialize` supplies `clientInfo`; Scriv then sends `initialized` without an ID. |
| Model discovery | `model/list` supplies `limit` and `includeHidden`; subsequent pages use `nextCursor` as `cursor`. The app chooses from the returned catalog. |
| Account read | `account/read` uses `refreshToken: false`. |
| ChatGPT login | `account/login/start` uses `type: "chatgpt"`; the returned `authUrl` opens in the browser. Login completion can report failure. |
| Logout | `account/logout` sends `params: null`. An empty object is rejected by the generated request schema. |
| Thread creation | `thread/start` supplies an isolated working directory, `approvalPolicy: "never"`, and `sandbox: "workspace-write"`. |
| Image reference input | `turn/start.input` accepts `{"type":"localImage","path":"/absolute/path.png"}` alongside a text instruction. |
| Cancellation | `turn/interrupt` supplies both `threadId` and `turnId`. |
| Command/file approval | Decline responses use `{"decision":"decline"}`. |
| Permission approval | A response granting no additional access uses `{"permissions":{},"scope":"turn"}`. The command/file decline shape is invalid for this method. |
| MCP elicitation | Decline uses `{"action":"decline","content":null}`. |
| Additional user input | An unanswered response uses `{"answers":{}}`; Scriv then interrupts the generation and asks for a revised image direction. |
| WebSocket messages | Outgoing JSON-RPC uses UTF-8 text frames. |

### Thread sandbox spelling

The generated **0.165.0 `ThreadStartParams.SandboxMode` enum** contains `read-only`, `workspace-write`, and `danger-full-access`. Scriv therefore uses `workspace-write` for `thread/start.sandbox`. The distinct `turn/start.sandboxPolicy` object uses camelCase discriminators such as `workspaceWrite`.

The official app-server documentation inspected during this audit showed a camelCase value in its thread-start example. The version-specific executable schema rejected that value, so the integration follows the generated schema. One negative fixture preserves this regression check.

## Generated image handling

The 0.165.0 generated `ThreadItem` schema includes an `imageGeneration` item with an optional absolute `savedPath`, a status, and optional failure information. Scriv observes completed image-generation items and the final turn's items. It also checks for the requested `storyboard.png` or `storyboard.jpg` deliverable after a successful turn.

Each generation has its own working directory. Reference images are copied into that directory. A reported artifact is accepted only when its resolved path stays inside the generation directory, it is a regular file rather than a symbolic link, it is at most 25 MiB, and AppKit can decode it as an image. The prompt asks Codex to copy the final output into that directory if the image tool initially saves elsewhere. A changed source revision causes the image to remain a project candidate instead of automatically replacing the current cue.

An image-generation item in the protocol establishes an artifact format; availability still depends on the installed runtime, selected model, account and runtime configuration. A successful turn without an image produces an actionable error. The integration never substitutes a placeholder for a successful generation.

## Reproduce the contract check

The optional checker requires **Python 3.10+** and **`jsonschema==4.25.1`**. These are verification dependencies; they are not Mac application runtime dependencies.

From the repository root, use an existing Codex 0.165.0 executable:

```sh
codex --version
codex app-server generate-json-schema --out /tmp/scriv-codex-schemas-0.165.0
python3 -m venv /tmp/scriv-codex-contract-venv
/tmp/scriv-codex-contract-venv/bin/python -m pip install jsonschema==4.25.1
/tmp/scriv-codex-contract-venv/bin/python scripts/check-codex-contract.py \
  /tmp/scriv-codex-schemas-0.165.0
```

Confirm that the first command reports `codex-cli 0.165.0`. To obtain that version without changing an existing global installation, npm can run the official pinned package:

```sh
npm exec --yes --package=@openai/codex@0.165.0 -- codex --version
npm exec --yes --package=@openai/codex@0.165.0 -- codex app-server \
  generate-json-schema --out /tmp/scriv-codex-schemas-0.165.0
```

The checker accepts `--fixtures PATH` for another fixture set and `--report PATH` to write a JSON result. It reads the generated schemas and validates local JSON. It does not launch Codex, access an account, or send fixture requests. Invalid payloads pass their regression check only when the schema rejects them. A missing schema, malformed fixture, or failed check exits nonzero.

For a runtime upgrade, generate that runtime's schemas into a separate directory and run the same fixtures first. Record the actual version independently, investigate every difference, and update the fixtures and implementation together. Do not label an upgraded runtime as verified merely because its version command succeeds.

## Required signed-in Mac smoke test

Schema validation is complete. Release verification still requires a real Mac and the intended account:

1. Start the installed Codex runtime from Scriv and confirm initialization, account state and model discovery. Stop it and verify that only Scriv's child process is terminated.
2. Sign into ChatGPT through Codex, verify the completion notification and refreshed model catalog, and keep the Scriv cloud sign-in independent.
3. Generate a storyboard image from a real scene. Confirm the resulting image file, cue attachment, local package persistence, and reopening behavior.
4. Generate with a copied character reference; cancel a separate in-progress generation; edit the source during another generation and verify candidate retention.
5. Exercise an unavailable capability or usage-limit response and confirm that the actual failure remains visible without a fabricated image.
6. If external loopback WebSocket support will be offered, test the exact runtime's listener, text frames, disconnect/reconnect behavior, and external process ownership. The official documentation labels this transport experimental.

These checks were **not performed by the schema audit**. They require explicit access to the intended runtime and account and can consume the account's generation allowance. Distribution and authentication eligibility for the chosen paid-service arrangement also remain a release requirement; see the [existing authentication design](multiplayer-design.md).

## Official references

- [Codex app-server protocol, transports and schema generation](https://learn.chatgpt.com/docs/app-server)
- [Codex developer commands](https://learn.chatgpt.com/docs/developer-commands)
- [Codex app-server integration and authentication guidance](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server)

For the tested payload spelling and item definitions, the generated 0.165.0 schemas and the committed verification result are the version-specific evidence.
