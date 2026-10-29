# Build checkpoints

This branch is being rebuilt as a new native Scriv application. Checkpoint commits
preserve implementation work; they are not release announcements.

## First implementation checkpoint — 2026-10-29

- Removed the inherited Movie AI Workspace implementation; its Git history remains.
- Preserved all 25 Scriv concept images and the product/timing/collaboration plans.
- Added native Swift models, timing, local project persistence, Fountain import/export,
  content hashing, cloud protocol models and a native cloud client.
- Added the Script/Storyboard UI and layered editor; remaining views are in progress.
- Added Cloudflare identity/team schema, OAuth, access control and project-room work.
- Added an encrypted WebRTC peer-media bridge and three generated sample frames.

Pending at this checkpoint: finish cross-component integration, cloud runtime tests,
Swift compilation, native visual review, billing verification and release packaging.
No service has been deployed and no payment has been created.

The final release report and deployment handoff will record actual verification results.
