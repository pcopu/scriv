# Old AppKit target retirement

The former AppKit/SwiftUI application and its build path are retired. The
current Catalyst app, server, updater and shared code remain.

## Scope

Removed 26 old-target-only Swift files: `ScrivApp/App.swift`, the AppKit
`ScrivApp/Services/WorkspaceErrorPresenter.swift`, and all 24 SwiftUI files under
`ScrivApp/Views/` except `ProjectHistoryPresentation.swift`. Also removed the old app Info.plist and entitlements, `build-mac.sh`,
`notarize-mac.sh`, and the old icon generator `make-icon.swift`. The approved
Catalyst icon assets and their verifier remain unchanged.

`apps/mac/Package.swift` now exports only `ScrivCore`. `npm run build:mac` and
`verify-native.sh --native` use the existing Catalyst builder. The existing GitHub Actions workflow is unchanged. Its legacy build
references remain incompatible with this retirement; updating CI is a separate
change.

## Preserved dependencies

- All current UIKit/Catalyst source, approved icon/resources, native update
  adapter, Sparkle policy, entitlements and runtime bootstrap helper.
- All `ScrivCore` sources. Eight shared services: WorkspaceStore, CloudClient,
  CloudClient+Generation, CodexController, CharacterAnalysisController,
  InternetPeerMedia, LocalAudioEngine and ResourceBundle.
- `Views/ProjectHistoryPresentation.swift`, PeerTransfer and SampleImages.
- All cloud API code, migrations, configuration and service journeys.
- All update Worker/release tooling and service journeys.
- Project formats and existing user data; no data migration or remote action.

The existing `apps/mac` paths intentionally remain to avoid an unrelated move
and preserve exact source associations. Platform-specific branches in shared
code are not bulk-deleted: native helpers and the Catalyst boundary have
different platform requirements.

## Recovery

The removed paths are recoverable from the last public main commit,
`4d14b29f4fb49891e850fa9a8e5742dc878603c8`. [The deletion manifest](appkit-retirement-20261109.json)
records their paths and SHA-256 hashes at that public baseline. Git history is
not rewritten. Restore the old target and its build configuration from that
commit into a separate checkout if needed;
do not mix old packaging back into the current Catalyst release.

## Verification boundary

Old-target removal adds no behavioral or measured coverage. Source maps, scenario restrictions and historical public source baselines
remain. Private execution records are not part of this publication.
Only obsolete comment declarations for deleted or changed files are removed.
Current Catalyst native compilation, matching automation builds, UI behavior,
release signing/notarization and signed-update installation remain separate
acceptance gates. Portable integrity/service results cannot establish them.
