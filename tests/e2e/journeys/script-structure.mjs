import { runScriptJourney } from './support/script-authoring-steps.mjs';
import { scriptStructureCases, structureExcluded } from './support/script-structure-cases.mjs';
import { createNavigateReopen } from './support/script-structure-steps.mjs';

// Prepared semantic stored-menu journey. The dedicated scene scope must be
// integrated/reviewed in the matching bundle; no generic action fallback exists.
await runScriptJourney({ journey: 'AUT-J03',
  workflows: { 'create-navigate-reopen': createNavigateReopen },
  cases: scriptStructureCases, excluded: structureExcluded });
