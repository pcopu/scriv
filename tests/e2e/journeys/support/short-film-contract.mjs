// Outcome first. This is an executable journey plan, not native evidence or a
// duplicate application model. Chapters cannot be selected or reset separately.
export const shortFilmContract = Object.freeze({
  id: 'FILM-J01', title: 'Make and revise a short film', nativeVerified: false,
  isolation: 'One owned isolated workspace, one new project, one unchanged sentinel; ten continuous chapters then one cold process relaunch, no fixture import or reset.',
  outcome: 'Reopen the same two-scene film with exact source, renamed character identity and links, historical picture selection, image tags and character portraits, audio placement/mix, timings and immutable identities intact.',
  chapters: [
    'create-project-and-preserve-sentinel', 'create-cast-and-write-opening',
    'revise-source-and-confirm-identity', 'import-revise-and-tag-picture',
    'choose-and-restore-character-portraits', 'attach-trim-and-mix-audio', 'create-second-scene-and-adjust-timing',
    'rename-linked-cast-without-rewriting-film', 'play-find-and-review-history', 'save-switch-away-reopen-and-prove-outcome',
    'cold-relaunch-and-reopen-owned-film',
  ],
  coldProfileOracle: 'Reopen the renamed character through the real editor after cold reload, require exact saved name, biography and appearance text including accents and whitespace, then clean-cancel without changing the film or sentinel. No colour-pixel or dirty-discard claim.',
  coldAudioOracle: 'Each clip card retains its own renamed attachment, volume and unmuted control; reopening and cancelling exact saved trim fields preserves the full film, revision, native Date bits and sentinel.',
  historyOracle: 'Each undo/redo accepts one revision, restores the complete expected film, preserves native immutable project/image Date bits and the unchanged sentinel, and leaves no alert. Read-only history preview stays nonmutating.',
  routes: ['Actual UIKit controls and native text/selection/key APIs',
    'Guarded stored public UIAction dispatch for scene, character portrait and direction-duration menus',
    'Production post-picker import with generated synthetic PNG/WAV bytes',
    'Read-only loaded-project, persisted-projects and local-image-evidence observers'],
  excluded: [
    'No claim of 100% source, branch, interaction or regression coverage; native execution and instrumentation still required.',
    'Rename project/scenes, aliases, delete/restore confirmations, arbitrary table/context menus and physical gestures need verified public routes.',
    'Dialogue-duration and individual word timing editors, split/merge, picture coverage editing and audio reattachment remain in separate journeys.',
    'Cold package reload is a native-unverified candidate; no startup-recovery, crash/power-loss durability, package export/import, microphone, file picker, audible-output or screenshot/pixel-layout claim.',
    'Portrait cropping/analysis, missing/remote assets and physical menu interaction remain outside the guarded stored-action candidate.',
    'No provider generation, account/cloud/network access, collaboration, user files or external services.',
  ],
});

export const film = Object.freeze({
  opening: 'A lantern glows beside the river.',
  firstLine: 'Ada, the lantern is ready.',
  draftLine: '🎬 Ada waits by the cafe\u0301.',
  revisedLine: '🎬 Ada waits by the café.',
  ending: 'The lantern crosses the quiet water.',
  revisedEnding: 'The lantern crosses the water at dawn.',
  lastLine: 'Béa, bring the lantern home.',
  cast: [
    { name: 'Ada', biography: 'A patient boat builder.\nKeeps a lantern.', appearance: 'Coral coat; silver scarf.', color: 'B072DB', swatch: 'Purple' },
    { name: 'Béa', biography: 'A careful navigator.\nReads the river.', appearance: 'Blue coat; a folded map.', color: '4E87EE', swatch: 'Blue' },
  ],
  revisedCast: { name: 'Ada Vale', biography: 'A boat builder who keeps the river’s lantern.\nNotes from the cafe\u0301.  ',
    appearance: 'Orange coat; silver scarf.\nA folded map in her pocket.', color: 'FF7E21' },
  imageHashes: ['827d9145314e931860ee40b45f8348ad3527c93e008d1490b687265d947fb577',
    '3fba282698b3df63c76fb40e529943fb6da6d28bafa6ff9e3a75c0c4a0cbb784'],
});
