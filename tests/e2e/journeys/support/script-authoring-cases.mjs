// Synthetic data and interaction-oriented review inventory, never saved fixtures.
export const sourceFixtures = {
  placeholder: 'New line', replacement: 'Hello there. café 🎬', suffix: ' Again.',
  fullText: 'CLI native editor café 🎬 regression', character: 'CLI Zelda Quinn',
  decomposed: 'cafe\u0301', composed: 'caf\u00e9', astronaut: '👩🏽‍🚀',
};
const unicode = '😀 One  cafe\u0301 👩🏽‍🚀 two  ';
export const returnCases = [
  { id: 'selected-word', name: 'Selected baseline word', text: 'One two', start: 4, end: 7 },
  { id: 'spaces-tab', name: 'Repeated spaces and tab', text: 'One  two\tthree', start: 5, end: 8 },
  { id: 'decomposed-joined-emoji', name: 'Selected decomposed word and joined emoji', text: unicode,
    start: unicode.indexOf('cafe\u0301'), end: unicode.indexOf(' two') },
  { id: 'empty-left', name: 'Collapsed caret at start', text: 'One', start: 0, end: 0 },
  { id: 'empty-right', name: 'Collapsed caret at end', text: 'One', start: 3, end: 3 },
];
export const sourceCases = [
  { group: 'write-exact-source', id: 'placeholder-consumed-once', interactions: ['SCR-08', 'SCR-03', 'SCR-04', 'SCR-05'],
    sourceSlice: 'editor-placeholder.mjs', route: 'type preserves observed native selection; never text/select-all',
    oracles: ['new focused ID and production placeholder selected in UTF-16', 'first insertion replaces; second appends at caret', 'finish resigns focus and displays exact text', 'same project has exactly one additional dialogue'] },
  { group: 'write-exact-source', id: 'unicode-range-refresh-history', interactions: ['SCR-08', 'SCR-03', 'SCR-04', 'SCR-05', 'SCR-37'],
    sourceSlice: 'editor-unicode-selection.mjs', route: 'text fixture setup; selection → type; zoom key-command; workspace history',
    oracles: ['surrogate/repeated-name/ZWJ/combining/whitespace ranges', 'exact source and saved word spellings at every edit', 'same entry/scene and other entry text', 'zoom retains focus and both selection endpoints without reselecting', 'canonical-only edit retains word IDs and all timing metadata', 'finish and exact decomposed undo/composed redo'] },
  { group: 'write-exact-source', id: 'replace-finish-history-character-companion', interactions: ['SCR-08', 'SCR-03', 'SCR-05', 'NAV-01', 'CHR-05', 'CHR-06', 'CHR-07', 'CHR-13'],
    sourceSlice: 'editing.mjs', companionJourney: 'AUT-J05', route: 'text replacement, workspace history, then Characters form in the same session',
    oracles: ['native Unicode text and finished display', 'enabled Escape; saved entry undo/redo', 'Characters tab and focused Name', 'Purple then Pink; saved CLI Zelda Quinn ribbon and F272AC colour'] },
  ...returnCases.map(test => ({ group: 'return-boundary', id: test.id, name: test.name,
    interactions: ['SCR-08', 'SCR-03', 'SCR-04', 'SCR-06', 'SCR-05'], sourceSlice: 'script-return-boundary.mjs',
    route: 'installed public UITextView edit delegate; not type/newline or physical key input',
    selection: [test.start, test.end],
    oracles: ['delegate rejects insertion', 'selected text survives in new focused right ID at caret zero',
      'exact saved source/words, scene, speaker and adjacent order', 'positive bounded ordered word timing and total duration/word-ID conservation',
      'unrelated entries remain fully exact', 'display-only empty placeholder; empty editor/package stays empty',
      'workspace undo/redo preserves all entry fields except existing characterLinks bootstrap allowance'] })),
];
export const boundaryCases = [0, 1, 2].map(pass => ({ group: 'scene-end-eligibility', id: `menu-pass-${pass + 1}`,
  interactions: ['NAV-01', 'NAV-03', 'SCR-10'], sourceSlice: 'script-menu-boundaries.mjs',
  route: pass ? 'Storyboard → Script; mounted context builder observation' : 'New → Script; mounted context builder observation',
  oracles: ['real blank one-scene two-entry template', 'first up disabled/down enabled; last up enabled/down disabled',
    'one native menu; nonhidden unique actions and native attributes', 'entries/scenes/cues/characters unchanged',
    'exactly one new package; every original saved package unchanged'] }));
export const searchFixtures = { first: 'CLI findprobequartz first findprobequartz café 🎬', second: 'CLI FINDPROBEQUARTZ second',
  mixedQuery: 'FiNdPrObEqUaRtZ', query: 'findprobequartz', missing: 'findprobequartz-no-such-line', unicodeQuery: 'café 🎬' };
export const searchCases = [
  { group: 'find-read-close', id: 'count-wrap-and-refocus', interactions: ['SCR-23', 'SCR-24', 'SCR-25'],
    oracles: ['empty focused header Find', 'case-insensitive count is entries not occurrences', 'next/previous both wrap',
      'Command-G/Shift-Command-G route', 'Command-F refocuses without clearing or closing', 'every mounted line remains present'] },
  { group: 'find-read-close', id: 'zero-unicode-recovery', interactions: ['SCR-24', 'SCR-25'],
    oracles: ['zero-results next/previous safe', 'Unicode one-result wrap', 'recover to multi-result query'] },
  { group: 'find-read-close', id: 'escape-close-reopen', interactions: ['SCR-23', 'SCR-24', 'SCR-26'],
    oracles: ['Escape and Close remove field/next/previous', 'both reopen with empty query', 'repeated search/dismiss',
      'same isolated saved project and exact unchanged entries'] },
].map(test => ({ ...test, sourceSlice: 'script-search.mjs', route: 'header/control activation and UIKit key-command routing' }));
