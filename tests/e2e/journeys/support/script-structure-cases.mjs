export const scriptStructureCases = [{
  group: 'create-navigate-reopen', id: 'scene-and-direction-lifecycle',
  nativeVerified: false, retirementAllowed: false,
  route: 'import-json → stored Script scene-button New scene → workspace Undo/Redo → empty-scene Add direction → text/Escape → scene selection → browser reopen',
  sourceRoutes: [
    'ScriptScreenController.sceneMenu → WorkspaceStore.addScene/selectScene',
    'ScriptScreenController.makeEmptyState → WorkspaceStore.addEntry(kind: .direction)',
    'ScriptScreenController editor → ScriptDraftSession → workspace Undo/Redo',
  ],
  oracles: ['exact complete saved and loaded model after each mutation',
    'new scene identity/order plus unchanged original scene and entry',
    'scene selection preserves packages and exact loaded Date witnesses',
    'Undo/Redo preserves new-scene identity; browser reopen preserves full model'],
}];
export const structureExcluded = [
  'physical menu presentation/dismissal',
  'Rename/Cancel/Delete UIAlertController execution: no verified permitted alert action route',
  'Move up/down execution: row context provider does not store its actions on a UIControl',
  'speaker assignment, deletion, lease/cloud/session paths',
  'frozen-method retirement and process relaunch',
];
export const sceneTitle = 'INT. NEW SCENE — DAY';
export function structureFixture() {
  return { schemaVersion: 1, id: 'script-structure-fixture', title: 'CLI scene structure fixture',
    createdAt: 1700000000000, modifiedAt: 1700000000000, revision: 0,
    scenes: [{ id: 'structure-original-scene', title: 'EXT. ORIGINAL GARDEN - DAY', order: 4 }],
    entries: [{ id: 'structure-original-direction', sceneId: 'structure-original-scene', order: 7,
      kind: 'direction', text: 'A gate stands open.', ownedDurationMs: 0,
      coverageDurationMs: 3000, color: 'purple', words: [], characterLinks: [] }],
    characters: [], images: [], cues: [], audioAssets: [], audioClips: [], audioVolume: 1 };
}
