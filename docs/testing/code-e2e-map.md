# Reviewed source/action/journey mapping

Use the installed Tracer CLI; the obsolete repository-local mapper has been
removed. From the Scriv repository root:

```sh
tracer check
tracer report --json
tracer measure check
tracer actions
tracer app -- test tooling
```

Review source and exact journey assertions before using `tracer link`. Preserve
unaffected associations; remove obsolete references when source/tests disappear.
Manual links are not execution coverage. Historical measurements retain their
original source hashes and stale entries. See [CLI-only testing](cli-only-tests.md)
and [the Tracer front door](tracer-front-door.md).
