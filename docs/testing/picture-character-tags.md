# Pictured-character tags

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

The `node tests/e2e/journeys/local-images.mjs --group tags` slice extends AUT-J08 with real UIKit manual tag controls. The default sequence includes versions, first-line navigation and tags.

A fresh synthetic two-character project imports two PNG versions through the existing post-picker importer, selects the historical version, and adds, removes, re-adds, then removes both tags. It closes/reopens the tag sheet and switches projects through the real browser. Every intentional toggle must produce exactly one saved revision; generated times are finite and nondecreasing because the application clock is millisecond-normalized.

The oracle compares complete saved projects, including the untouched successor version, source content, characters, and unrelated sample. The first tag removal creates a manual analysis exclusion marker; subsequent changes must retain its completion time while updating exclusions/manual IDs exactly. Loaded model/date witnesses and decoded image/hash evidence are checked only after dismissal, preserving the observation boundary that rejects tag sheets.

The slice does not claim successor-version tag UI inspection, automatic analysis, portrait assignment/reset, physical input, full rendered pixel comparison, or equivalent retirement of legacy analysis tests. Source review and native evidence are separate.

The test waits for the image picker to disappear and the preview control to become hittable before observing loaded state. This preserves the production observation gate.
