// Synthetic input and independent literal output oracles. No production parser,
// validator, model setter or native driver is imported by this fixture module.
export const literalDirection = 'RUN\nINT. remains a direction.\n@camera stays still\n[[scriv duration=999]]';
export const documentSource = '\uFEFF' + [
  '', 'tItLe:', '    Midnight Ledger', '    Return', 'Author: Test Writer',
  'Custom-key: ignored title-page metadata', '', '[[scriv duration=123 coverage=456]]', '', 'INT. ARCHIVE - NIGHT', '',
  '!RUN', 'INT. remains a direction.', '@camera stays still', '[[scriv duration=999]]', '',
  '[[scriv duration=1500 coverage=2500 duration=-1 duration=3600001 coverage=86400001 duration=NaN coverage=NaN]]', '',
  '@MARA (V.O.)', '(quietly)', 'We wait.', '', '[[scriv duration=0 coverage=7]]', '',
  '@mara (CONT\'D)', 'Return now.', '', '[[scriv duration=1800 coverage=0]]', '',
  '.An empty interlude', '', '.The final room', '', '!CUT TO:', '', '[[scriv duration=0 coverage=0]]',
].join('\r\n');
export const expectedDocument = {
  title: 'Midnight Ledger\nReturn',
  scenes: ['INT. ARCHIVE - NIGHT', 'An empty interlude', 'The final room'],
  entries: [
    { scene: 0, order: 0, kind: 'direction', text: literalDirection, speaker: null, duration: 1500, coverage: 2500, words: [] },
    { scene: 0, order: 1, kind: 'direction', text: '(quietly)', speaker: null, duration: 0, coverage: 3000, words: [] },
    { scene: 0, order: 2, kind: 'dialogue', text: 'We wait.', speaker: 'Mara', duration: 2, coverage: 7,
      words: [{ text: 'We', startMs: 0, endMs: 1 }, { text: 'wait.', startMs: 1, endMs: 2 }] },
    { scene: 0, order: 3, kind: 'dialogue', text: 'Return now.', speaker: 'Mara', duration: 1800, coverage: 0,
      words: [{ text: 'Return', startMs: 0, endMs: 1079 }, { text: 'now.', startMs: 1079, endMs: 1800 }] },
    { scene: 2, order: 4, kind: 'direction', text: 'CUT TO:', speaker: null, duration: 0, coverage: 0, words: [] },
  ],
  characters: [{ name: 'Mara', aliases: [] }],
  cues: [{ scene: 0, label: '01A', startMs: 0, endMs: 3302 }],
};
export const expectedExport = [
  'Title:', '    Midnight Ledger', '    Return', '', '', 'INT. ARCHIVE - NIGHT', '',
  '!' + literalDirection, '', '[[scriv duration=1500 coverage=2500]]', '',
  '!(quietly)', '', '[[scriv duration=0 coverage=3000]]', '',
  '@MARA', 'We wait.', '', '[[scriv duration=2 coverage=7]]', '',
  '@MARA', 'Return now.', '', '[[scriv duration=1800 coverage=0]]', '',
  '.An empty interlude', '', '.The final room', '', '!CUT TO:', '', '[[scriv duration=0 coverage=0]]', '',
].join('\n');
export const boundaryDocuments = [
  { key: 'metadata-only', filename: 'Empty.fountain', text: 'Author:\n\tTest Writer\nCustom-key: ignored\n',
    expected: { title: 'Empty', scenes: ['INT. SCENE — DAY'], entries: [], characters: [], cues: [] },
    exported: 'Title: Empty\n\n\nINT. SCENE — DAY\n' },
  { key: 'plain-opening', filename: 'Plain.fountain', text: 'Warning: Keep the door shut.\n\nCUT TO:\n\nINT. EXIT - DAY\n\n!Wait.',
    expected: { title: 'Plain', scenes: ['INT. SCENE — DAY', 'INT. EXIT - DAY'],
      entries: [
        { scene: 0, order: 0, kind: 'direction', text: 'Warning: Keep the door shut.', speaker: null, duration: 1875, coverage: 1875, words: [] },
        { scene: 0, order: 1, kind: 'direction', text: 'CUT TO:', speaker: null, duration: 1000, coverage: 1000, words: [] },
        { scene: 1, order: 2, kind: 'direction', text: 'Wait.', speaker: null, duration: 1000, coverage: 1000, words: [] },
      ], characters: [], cues: [{ scene: 0, label: '01A', startMs: 0, endMs: 2875 }, { scene: 1, label: '01A', startMs: 0, endMs: 1000 }] },
    exported: ['Title: Plain', '', '', 'INT. SCENE — DAY', '', '!Warning: Keep the door shut.', '',
      '[[scriv duration=1875 coverage=1875]]', '', '!CUT TO:', '', '[[scriv duration=1000 coverage=1000]]', '',
      'INT. EXIT - DAY', '', '!Wait.', '', '[[scriv duration=1000 coverage=1000]]', ''].join('\n') },
];
export const searchCases = [
  { key: 'speaker-name', query: 'mArA', counts: ['1 / 2', '2 / 2', '1 / 2', '2 / 2', '1 / 2'] },
  { key: 'speaker-alias', query: 'nIgHtWaTcH', counts: ['1 / 2', '2 / 2', '1 / 2', '2 / 2', '1 / 2'] },
  { key: 'missing', query: 'unfindable-6831', counts: ['0 results', '0 results', '0 results', '0 results', '0 results'] },
  { key: 'literal-source', query: 'camera', counts: ['1 / 1', '1 / 1', '1 / 1', '1 / 1', '1 / 1'] },
  { key: 'clear', query: '', counts: ['', '', '', '', ''] },
];
export const excluded = [
  'Native document picker and physical keyboard event delivery', 'Find-field Return (CLI return requires UITextView)',
  'External file destinations and export cancellation', 'App relaunch or crash recovery',
  'Alias editing UI, script mutation, undo/redo and duration-sheet editing',
  'Cloud leases, security-scoped grant failures, production 16 MiB/invalid UTF-8 guards beyond the bounded UTF-8 CLI envelope',
  'Full JSON schema validation and exhaustive Fountain grammar',
];
