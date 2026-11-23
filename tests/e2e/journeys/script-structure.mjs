import { runScriptJourney } from './support/script-authoring-steps.mjs';
import { scriptStructureCases, structureExcluded } from './support/script-structure-cases.mjs';
import { createNavigateReopen } from './support/script-structure-steps.mjs';
import { moveAndDeleteStructure } from './support/script-structure-edits.mjs';

await runScriptJourney({ journey: 'AUT-J03',
  workflows: { 'create-navigate-reopen': createNavigateReopen, 'move-delete': moveAndDeleteStructure },
  cases: scriptStructureCases, excluded: structureExcluded });
