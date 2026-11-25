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
}, {
  group: 'move-delete', id: 'reorder-and-remove-script-structure',
  nativeVerified: false, retirementAllowed: false,
  route: 'import-json → selected entry menu → move down/up → entry Delete/Cancel → scene Delete/Cancel → workspace Undo/Redo',
  sourceRoutes: [
    'ScriptScreenController.structureActions → WorkspaceStore.moveEntry/deleteEntry',
    'ScriptScreenController.sceneMenu → WorkspaceStore.deleteScene',
  ],
  oracles: ['visible row order and exact saved and loaded entries, timing and anchored placements',
    'disabled actions and incorrect targets preserve the complete loaded and persisted projects',
    'explicit confirmation and cancellation for entry and scene removal',
    'Undo/Redo restores and replays scene removal; unrelated package stays identical',
    'moving between consecutive representable orders renumbers only the affected scene'],
}, {
  group: 'owned-duration-dialog', id: 'draft-owned-duration-for-direction',
  nativeVerified: false, retirementAllowed: false,
  route: 'import-json → Script row Edit owned duration → presented-alerts → type into Seconds',
  sourceRoutes: ['ScriptEntryRow.durationButton → ScriptScreenController.editDuration'],
  oracles: ['exact attached Owned duration dialog for the imported direction, including Cancel and Apply presentation',
    'the covered workspace is unavailable and a pending field draft leaves the complete loaded and saved projects exact'],
}];
export const structureExcluded = [
  'physical menu presentation/dismissal',
  'rename-scene alert, owned-duration alert button activation and physical row context menu interactions',
  'speaker assignment, lease/cloud/session paths',
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
