# Native Scriv views

These images were captured from the actual packaged SwiftUI/AppKit application,
using its native window content at **1440 × 970**. They are unmodified PNGs from
[successful CI run 40921544866](https://github.com/pcopu/scriv/actions/runs/40921544866),
built from runtime commit [`0eb779b`](https://github.com/pcopu/scriv/commit/0eb779b8e07935235d4584b09abe05bd0504be01).

The final captures are byte-identical to the three captures already visually
reviewed after the last interface corrections. Their SHA-256 digests, artifact
provenance and runtime test results are in [native-ci.json](../verification/native-ci.json).
The original conversation concepts remain in [design/images](../../design/images).

## Script

One left-aligned script flow with independent owned time and forward direction
coverage, linked character names, image preview and the layered playback editor.

![Actual native Script view](01-script.png)

## Characters

Script-linked profiles, aliases, portraits and images tagged with their depicted
characters.

![Actual native Characters view](02-characters.png)

## Storyboard

Full-width image cards with duration pills, selectable words, overlapping
direction bands and fixed playback controls. The lower rows continue by scrolling.

![Actual native Storyboard view](03-storyboard.png)

## Build artifact

The [verified Mac artifact](https://github.com/pcopu/scriv/actions/runs/40921544866/artifacts/12918682797)
contains `Scriv-macOS.zip`, these captures and the native peer-transfer report.
The ZIP contains a universal executable for Intel and Apple Silicon; runtime smoke tests
ran on Intel. It is an ad-hoc-signed development build with a local API default.
Production signing, notarization, configuration and account-bound acceptance
are covered by the [deployment handoff](../deployment.md).
