# Scriv

A script-first Mac workspace for writing, timed storyboards, character references and collaboration.

Write the script, give spoken lines and actions their own time, attach images to words, and play the result. Directions can extend forward over later content while owning either zero seconds or a dedicated action slot.

**Status: design only.** This repository collects the plans, selected interface concepts and timing examples developed for Scriv. The new application implementation has not started.

![Scriv script editor concept](design/images/01-script-editor.png)

## Selected views

| View | Design |
| --- | --- |
| [Script editor](design/images/01-script-editor.png) | One aligned script flow, a shared colored direction rail, image preview and layered playback editor. |
| [Characters](design/images/02-characters.png) | Linked character profiles, aliases and images tagged with the characters they depict. |
| [Storyboard](design/images/03-storyboard.png) | Full-width images, overlaid duration pills, selectable spoken-word pills and direction coverage bands. |
| [Collaboration and local Codex](design/images/04-collaboration-local-codex.png) | Live collaborators, item discussions, history and separate controls for Codex running on the user's Mac. |

## Design documents

- [Product and interaction design](docs/design.md): the current visual direction and editing rules.
- [Multiplayer, storage and local Codex architecture](docs/multiplayer-design.md): proposed persistence, collaboration, history, billing and local runtime responsibilities.
- [Storyboard timing example](design/storyboard-timing-example.json): exact provisional timings, stable word identities, image assignments and direction coverage.

- [Earlier design iterations](design/archive/README.md): all 21 earlier images, retained as design history.
- [Image preservation manifest](design/manifest.json): source names, dimensions, byte sizes and checksums for all 25 chat-generated images.

The mockups illustrate layout and interaction. The timing fixture records precise example values.

## Core decisions

- The script is the source of truth; views share stable item, word, character and image identities.
- Direction coverage and owned sequence time are separate. Extending coverage adds no time.
- Images can cover several words or script entries. Moving a cut preserves the wording and word order.
- Collaboration uses live cursors, exclusive editing of each script item, durable history and per-item discussions.
- Codex generation runs on the user's Mac. Cloud services handle scripts, collaboration, history and premium image storage.

There is no runnable application, installation procedure or deployed service in this design repository yet.
