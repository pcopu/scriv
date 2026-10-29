# Scriv

A native Mac workspace for writing a script, timing its words and directions, and playing it as a visual storyboard.

Scriv is a new SwiftUI/AppKit application. The inherited Movie AI Workspace implementation has been removed; the Git history and all 25 Scriv design images remain available. The cloud service runs on Cloudflare Workers, D1, SQLite Durable Objects and private R2 storage.

**Current source handoff:** the later workspace, audio, discussion, history, generation, source-owned timing, character-link, durable editor recovery, email sign-in and collaboration changes are described in the [current integration handoff](docs/verification/current-handoff.md). These changes have **not** been compiled or run as a native Mac app in the Linux workspace. The successful [historical CI run](https://github.com/pcopu/scriv/actions/runs/40921544866), universal development build and screenshots apply only to [runtime commit `0eb779b`](https://github.com/pcopu/scriv/commit/0eb779b8e07935235d4584b09abe05bd0504be01), not current `main`. [Verification](docs/verification.md) separates those results from current local evidence; the [deployment handoff](docs/deployment.md) retains production, signing and live-account acceptance gates.

**Backend:** deployed at `https://scriv-api.muddy-recipe-a722.workers.dev`, with D1, private R2 and email-code login. [Deployment evidence](docs/verification/cloud-deployment-20261029.md) distinguishes service checks from delivery/session acceptance. Stripe and multiplayer acceptance are deferred; native release/signing remains unverified.

![Scriv native Script view](docs/screenshots/01-script.png)

*Actual SwiftUI/AppKit application capture. View the [Script](docs/screenshots/01-script.png), [Characters](docs/screenshots/02-characters.png) and [Storyboard](docs/screenshots/03-storyboard.png) screenshots, with build provenance in the [capture notes](docs/screenshots/README.md). The original approved concepts remain in [design/images](design/images).*

## The workspace

| View | What it does |
| --- | --- |
| **Script** | One left-aligned flow of dialogue and direction, duration pills, linked character names, forward-extending colored direction rails, image preview and layered playback editor. |
| **Storyboard** | Full-width image cards, duration pills, individual word selection and rectangular marquee selection. Drag a shared cut or a contiguous edge-word selection between neighboring images. |
| **Characters** | Stable character profiles and aliases, appearance notes, portraits, tagged images and immutable image versions. |
| **Discussion** | A compact project/item panel with replies, image-version attachments and resolved threads. |
| **History** | Local saved revisions and the complete paginated cloud event history; restoring creates a new revision. |

Directions have **owned time** and **coverage**. A direction may own zero seconds while extending forward over other lines. Extending its coverage never adds time. Moving an image cut preserves the two cues' combined duration and the script's word order. The [design specification](docs/design.md) and [timing fixture](design/storyboard-timing-example.json) define the interaction precisely.

The bundled farm-scene sample includes the full 56.3-second authored sequence and three real sample images. The selected storyboard excerpt retains its original full-scene time offsets.

## Free and Team

| Capability | Free personal project | Team — USD $9.99/month |
| --- | --- | --- |
| Local writing, timing, playback, import/export | Included | Included |
| Hosted scripts, character metadata and history | Included after Scriv sign-in | Included |
| Local Codex image generation | Uses your own local Codex account | Uses each member's own local Codex account |
| Image transfer between authorized devices | Your own devices | Team members' devices |
| Live collaboration, cursors and exclusive item editing | — | Included |
| Project/item discussions with collaborators | — | Included |
| Private hosted image replicas | — | Included within the configured storage quota |
| Team membership | One person | No per-seat charge or membership cap |

The subscription is **one recurring $9.99 USD payment per team, quantity one**. Owners can create reusable, expiring and revocable invitation links. Viewers, members, admins and the owner have distinct permissions. The initial hosted-media quota is 10 GiB/team and 25 MiB/image; membership is not metered. There is a 1,000-connection protection limit per live project room, independent of team membership.

Cloudflare's Workers Paid plan is the infrastructure starting point. Its $5 base fee is not a promise that all storage, requests, Durable Object work and optional TURN traffic will fit within $5. See [deployment and capacity notes](docs/deployment.md).

## Run on a Mac

Requirements: macOS 14+, Xcode 15.4+ or a compatible newer Swift toolchain. OpenAI Codex is optional for writing and playback; install it separately if you want image generation.

```sh
git clone https://github.com/pcopu/scriv.git
cd scriv
swift test --package-path apps/mac
bash scripts/build-mac.sh
open build/Scriv.app
```

The package script produces `build/Scriv.app` and `build/Scriv-macOS.zip`. Development builds are ad-hoc signed. A distributable release requires your Developer ID signing identity and Apple notarization; the scripts and exact commands are in the [handoff](docs/deployment.md).

The app opens locally without signing in. Use **File → Open Project** for a `.scriv` package, **Import Script** for Fountain/plain-text scripts, or the sample project to explore the three views. The sample, local saves and local history do not require the cloud. Settings can select the deployed API URL; the development default is `http://127.0.0.1:8787`.

### Two independent accounts

**Scriv account:** the account control sends a six-digit email code and verifies it in the app to access hosted scripts and teams. Codes are short-lived, single-use and bound to the requesting sign-in flow. Scriv session tokens are stored in Keychain and scoped to the API origin. Existing GitHub identities remain supported separately; matching contact emails do not silently merge accounts.

**Codex on this Mac:** Start launches the installed `codex app-server` as a child process. Connect attaches to an explicitly configured loopback WebSocket endpoint. Sign in with ChatGPT is handled by Codex. Stop terminates only the child Scriv started; disconnecting an external server leaves that server running. No ChatGPT credential is sent to Scriv's cloud.

Image generation requests a real image file in an isolated local generation directory. The installed Codex runtime, selected model and account must support image generation. Scriv reports an actual missing-capability or missing-file error instead of substituting an image. This integration still requires the live-account release smoke test described in the handoff.

The protocol is checked against the official Codex **0.165.0** generated schema, with 21 passing contract checks. See [Codex integration](docs/codex-integration.md) for the tested version and reproducible validation.

## Run the backend locally

Requirements: Node.js 22.14+ and npm. Cloud credentials are unnecessary for the isolated automated tests.

```sh
npm ci
npm --prefix cloud ci
cp cloud/.dev.vars.example cloud/.dev.vars
npm --prefix cloud run db:migrate:local
npm run dev:cloud
```

The isolated email-auth tests inject a fake sender and never send live mail. Interactive email sign-in requires a configured Email Sending binding and verified sender, or point the app at the deployed HTTPS service. Optional legacy GitHub OAuth needs a separate development OAuth app. There is no local authentication bypass. Stripe and TURN remain separate optional integrations; see [cloud setup](cloud/README.md).

## Verify

```sh
npm run check
npm test
npm --prefix cloud run test:load
npx playwright install chromium
npm run test:peer
# Linux or macOS with an official Swift toolchain:
bash scripts/verify-native.sh --portable
# macOS only, for actual native app compilation and packaging:
bash scripts/verify-native.sh --native
```

The Cloudflare tests run inside the real Workers runtime with local D1, Durable Objects and R2 bindings. The peer tests use real Chromium WebRTC data channels. Swift core tests and optimized core builds run on Linux using the portable verification wrapper, which uses project-local caches. `npm run verify` now requires Swift rather than skipping those checks. Compiling the native interface and rendering its screenshots require macOS; parsing Swift source on Linux is not native UI type-checking. See [current local native evidence](docs/verification/doppler-linux-native.md).

CI runs the backend, fixture and six real-browser peer tests plus the native Mac build. It packages a universal `.app`, checks a real multi-chunk transfer between two native WebKit bridges, then captures all three native views. The browser cases include simultaneous requests on throttled CPUs, ICE arriving before SDP, either device initiating, reconnection, and retry after lost signaling. CI does not deploy, create Stripe charges, sign with a private Developer ID certificate or log into a ChatGPT account.

## Project map

- [structure.md](structure.md): complete source map, runtime responsibilities and file formats.
- [Current architecture and schema](docs/architecture.md): local storage, cloud schema, collaboration and billing decisions.
- [Cloud API](docs/cloud-api.md): the native/server protocol and error contract.
- [Deployment handoff](docs/deployment.md): configuration, release commands, production smoke tests and rollback.
- [Verification report](docs/verification.md): measured results and explicit production-account gates.
- [Product design](docs/design.md), [current concepts](design/images) and [earlier concepts](design/archive/README.md).
- [Original multiplayer proposal](docs/multiplayer-design.md): retained design history; its Redis/Postgres/$10 proposal is superseded by the current Cloudflare/$9.99 implementation.

MIT licensed. See [LICENSE](LICENSE).
