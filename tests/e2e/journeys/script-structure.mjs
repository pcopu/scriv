import { runScriptJourney } from './support/script-authoring-steps.mjs';
import { scriptStructureCases, structureExcluded } from './support/script-structure-cases.mjs';
import { createNavigateReopen } from './support/script-structure-steps.mjs';
import { observeOwnedDurationDialog } from './support/script-owned-duration-steps.mjs';
import { moveAndDeleteStructure, changeDialogueSpeaker } from './support/script-structure-edits.mjs';

await runScriptJourney({ journey: 'AUT-J03',
  workflows: { 'create-navigate-reopen': createNavigateReopen, 'move-delete': moveAndDeleteStructure,
    'owned-duration-dialog': observeOwnedDurationDialog, 'speaker-choice': changeDialogueSpeaker },
  groupWitnessPaths: {
    'create-navigate-reopen': ['tests/e2e/journeys/support/script-structure-steps.mjs'],
    'move-delete': ['tests/e2e/journeys/support/script-structure-edits.mjs'],
    'owned-duration-dialog': ['tests/e2e/journeys/support/script-owned-duration-steps.mjs'],
    'speaker-choice': ['tests/e2e/journeys/support/script-structure-edits.mjs'],
  },
  groupActions: { 'speaker-choice': [
    { id: 'script-change-speaker', command: 'menu-action', trigger: 'Change speaker',
      condition: 'select-an-existing-speaker-or-clear-the-selected-dialogue',
      entryPoint: { path: 'apps/catalyst/ScrivUIKit/Script/ScriptScreenController.swift', start: 470, end: 475,
        sha256: '3ded3acf5bfb91d7a33dc2a80f09cb71143c95fb2e64bacca19725547746824c' },
      branch: { path: 'apps/mac/Sources/ScrivApp/Services/WorkspaceStore.swift', start: 1117, end: 1117,
        sha256: '734c69e597957f20c94bdad48b02ce9d6eccf9177b302c069650c47ab2a732b3' } },
  ] },
  cases: scriptStructureCases, excluded: structureExcluded });
