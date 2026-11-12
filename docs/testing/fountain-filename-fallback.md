# Filename-derived import titles

This document describes source behavior and verification requirements. It does not publish historical execution records or attest to a passing run.

Candidates: apps/mac/Tests/ScrivCoreTests/FountainTests.swift::0010 and ::0014,
frozen source SHA ef94a9c83bd09dcd8055f876a1126f06d16286f2bffc816795a6e3b05bd71e8b.
All original input strings, fallback titles and value assertions are retained.
The production importer obtains each fallback from its actual file basename;
there is no parser parameter or model assignment in the driver.

The CLI accepts optional `filename`, a single component at most 128 UTF-8 bytes,
with required `.fountain` suffix. Leading dots, slash, backslash, colon and
control characters are rejected. Arbitrary paths/URLs remain prohibited.
Every invocation creates an exclusive 0700 UUID child directory inside this
run's private app-owned root, then an exclusive 0600 no-follow file. Existing
root/package ownership and descriptor checks remain. Cleanup only unlinks the
created file by matching inode, then the matching empty directory. Repeated
basenames cannot collide. Default filename is `Import.fountain`.

Rejections assert unchanged persisted packages. Five accepted imports cover
both frozen methods, including all four opening-colon literals, and preserve
all earlier saved packages. Each installed package passes the actual production
validator before publication. No external file/picker or permission behavior
is exercised. Native compilation/scenario pending; legacy methods retained.
