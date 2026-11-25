import { runScriptJourney } from './support/script-authoring-steps.mjs';
import { scriptStructureCases, structureExcluded } from './support/script-structure-cases.mjs';
import { createNavigateReopen } from './support/script-structure-steps.mjs';
import { observeOwnedDurationDialog } from './support/script-owned-duration-steps.mjs';
import { moveAndDeleteStructure } from './support/script-structure-edits.mjs';

await runScriptJourney({ journey: 'AUT-J03',
  workflows: { 'create-navigate-reopen': createNavigateReopen, 'move-delete': moveAndDeleteStructure, 'owned-duration-dialog': observeOwnedDurationDialog },
  groupWitnessPaths: {
    'create-navigate-reopen': ['tests/e2e/journeys/support/script-structure-steps.mjs'],
    'move-delete': ['tests/e2e/journeys/support/script-structure-edits.mjs'],
    'owned-duration-dialog': ['tests/e2e/journeys/support/script-owned-duration-steps.mjs'],
  },
  cases: scriptStructureCases, excluded: structureExcluded });
