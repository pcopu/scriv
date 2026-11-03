# Scriv in-app updates

The Catalyst application uses a UIKit update sheet and a separate native macOS `ScrivUpdatePlugin.bundle` linked to the exact Sparkle 2.10.1 package. Foundation/Objective-C callbacks cross the boundary; Catalyst does not link AppKit or implement a shell installer. The app remains sandboxed; only the two app-scoped Sparkle Mach service names are permitted. Bundle identity remains `app.scriv.uikit`; the displayed/product name is Scriv.

## User control and durable saves

**Scriv → Check for Updates…** starts a manual check. **Scriv → Settings…** (⌘,) opens the separate native Settings window; repeated requests focus that same window. Automatic checks/install and optional profiling are disabled. Download preparation and Update & Relaunch each require every workspace to finish editing and prove that pending saves/journals are durable. Active generation, conflicts, save errors or on-disk drift block installation.

Sparkle can install a prepared update when the app quits. **Later** therefore cancels preparation using Skip rather than merely dismissing it. Rejected metadata or a failed save fence also returns Skip immediately, independently of the error notice. One-shot callbacks and generation guards prevent stale/repeated actions from authorizing another installation. The modal handoff clears the presenting sheet before advancing the update flow.

Update code does not delete or upload project packages, recovery journals or user credentials. Failed-install recovery is Sparkle's responsibility; bad-but-valid releases require an explicitly published higher-build recovery release, not downgrade bypasses.

## Trust boundary

- Only intact Developer ID-signed hosts under the configured team and bundle identity can enable updates. Development/ad-hoc builds stay blocked.
- A public Ed25519 pin verifies both feed and archive. Private keys remain in the operator's existing Keychain; scripts never create or export them.
- Signed feeds and verification before extraction are required. Unsigned-feed expiry fallback is disabled.
- The fixed HTTPS origin, signed app channel, signed feed item channel, artifact path, and increasing build must agree.
- The release script verifies the app and nested helpers, notarization, signatures, packaged bytes and final Ed25519 signatures before publication.
- The separate Worker serves only allowlisted public release objects from private R2. It has no publisher endpoint. Immutable artifacts are create-once; the channel pointer is committed last with conditional writes.

## Development and release

```sh
bash scripts/build-catalyst.sh
# build/catalyst/Build/Products/Release-maccatalyst/Scriv.app
node --test tests/*.test.mjs
npm --prefix updates test
```

Development builds are not a production release. Native UIKit interaction, signed installation/relaunch, runtime pairing, cancellation and user-data preservation remain distinct acceptance gates. See [signed update acceptance](signed-update-acceptance.md) and [update service setup](../updates/README.md). Keep build/device diagnostics and original receipts private; none are required in source control.
