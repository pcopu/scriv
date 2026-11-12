import assert from 'node:assert/strict';

// Exact synthetic fixtures and behavioral oracles from fountain-import.mjs.
// Case callbacks only observe saved app output; they do not parse or validate it.
const prefix = 'apps/mac/Tests/ScrivCoreTests/FountainTests.swift::';
const textOf = project => project.entries.map(entry => entry.text);
const titlesOf = project => project.scenes.map(scene => scene.title);
const frozen = (number, name, text, verify) => ({ id: prefix + number, name, text, verify });
export const importCases = [
  frozen('0002', 'parenthetical is an unspoken forward direction',
    'Title: A Scene\n\nINT. ROOM - DAY\n\nJASON\n(angrily)\nYou stupid guy!\n\nJason turns toward Bonny.\n', project => {
      assert.equal(project.entries.length, 3);
      assert.equal(project.entries[0].kind, 'direction');
      assert.equal(project.entries[0].ownedDurationMs, 0);
      assert.deepEqual(project.entries[0].words, []);
      assert.equal(project.entries[1].kind, 'dialogue');
      assert.equal(project.entries[1].text, 'You stupid guy!');
    }),
  frozen('0003', 'CRLF and scene order',
    'EXT. FARM - DAY\r\n\r\nThe farmer waits.\r\n\r\nINT. BARN - NIGHT\r\n\r\nA lamp flickers.\r\n', project => {
      assert.equal(project.scenes.length, 2);
      assert.equal(project.entries.length, 2);
      assert.equal(project.cues.length, 2);
      // Extra order checks, beyond the three frozen count assertions.
      assert.deepEqual(titlesOf(project), ['EXT. FARM - DAY', 'INT. BARN - NIGHT']);
      assert.deepEqual(textOf(project), ['The farmer waits.', 'A lamp flickers.']);
    }),
  frozen('0005', 'immediate timing metadata applies to preceding dialogue',
    'INT. ROOM\n\n@RANDY\nHello there\n[[scriv duration=2000 coverage=0]]', project => {
      assert.equal(project.entries.length, 1);
      assert.equal(project.entries[0].ownedDurationMs, 2000);
      assert.equal(project.entries[0].coverageDurationMs, 0);
      assert.equal(project.entries[0].words.at(-1)?.endMs, 2000);
    }),
  frozen('0006', 'mid-dialogue parenthetical preserves speaker',
    "INT. ROOM\n\nRANDY\nBefore.\n(whispering)\nAfter.\n\nRANDY (CONT'D)\nStill me.\n", project => {
      assert.deepEqual(textOf(project), ['Before.', '(whispering)', 'After.', 'Still me.']);
      assert.equal(project.characters.length, 1);
      assert.equal(project.entries[0].characterId, project.entries[2].characterId);
      assert.equal(project.entries[2].characterId, project.entries[3].characterId);
      assert.deepEqual(project.entries[1].words, []);
      assert.equal(project.entries[1].ownedDurationMs, 0);
    }),
  // Corrected CI fixture, NOT an unchanged input from frozen baseline ::0007.
  // A blank line terminates forced action before malformed timing metadata.
  frozen('0007', 'corrected malformed annotation after terminated forced action',
    '.First empty scene\n\n.Second scene\n\n!Wait.\n\n[[scriv duration=-1 coverage=99999999999999999999]]', project => {
      assert.deepEqual(titlesOf(project), ['First empty scene', 'Second scene']);
      assert.equal(project.entries.length, 1);
      assert.equal(project.entries[0].ownedDurationMs, 1000);
      assert.equal(project.entries[0].text, 'Wait.');
      assert.equal(project.entries[0].coverageDurationMs, 1000);
    }),
  frozen('0008', 'title author does not create timed entry or scene',
    'Title: Audit fixture\nAuthor: Test Writer\n\nINT. ROOM - DAY\n\n@JASON\nHello there.\n', project => {
      assert.equal(project.title, 'Audit fixture');
      assert.deepEqual(titlesOf(project), ['INT. ROOM - DAY']);
      assert.deepEqual(textOf(project), ['Hello there.']);
      assert.deepEqual(project.characters.map(character => character.name), ['Jason']);
      assert.equal(project.cues.length, 1);
    }),
  frozen('0011', 'UTF-8 BOM CRLF and tab-indented title metadata',
    '\uFEFFTitle:\r\n\tBOM title\r\nAuthor:\r\n\tTest Writer\r\n\r\nINT. ROOM - DAY\r\n\r\n!Wait.\r\n', project => {
      assert.equal(project.title, 'BOM title');
      assert.equal(project.scenes.length, 1);
      assert.deepEqual(textOf(project), ['Wait.']);
    }),
  frozen('0012', 'non-metadata ends title page without blank separator',
    'Title: No separator\nAuthor: Test Writer\nINT. ROOM - DAY\n\n!Wait.', project => {
      assert.equal(project.title, 'No separator');
      assert.deepEqual(titlesOf(project), ['INT. ROOM - DAY']);
      assert.deepEqual(textOf(project), ['Wait.']);
    }),
  frozen('0013', 'title-like body and forced action are not metadata',
    'Title: Actual title\n\nTitle: A card in the screenplay.\n\nINT. ROOM - DAY\n\n!Author: Not metadata.', project => {
      assert.equal(project.title, 'Actual title');
      assert.deepEqual(textOf(project), ['Title: A card in the screenplay.', 'Author: Not metadata.']);
    }),
  frozen('0013', 'literal opening forced action is not metadata',
    '!Author: A literal opening action.\n\nINT. ROOM - DAY', project => {
      assert.deepEqual(textOf(project), ['Author: A literal opening action.']);
    }),
  frozen('0013', 'opening transition is not metadata',
    'CUT TO:\n\nINT. ROOM - DAY', project => {
      assert.deepEqual(textOf(project), ['CUT TO:']);
    }),
  ...['', '\n\n', 'Title: Metadata only\nAuthor: Writer', 'Author:\n\tOne Writer'].map((text, index) =>
    frozen('0015', `empty or metadata-only input ${index + 1}`, text, project => {
      assert.equal(project.scenes.length, 1);
      assert.deepEqual(project.entries, []);
      assert.deepEqual(project.cues, []);
    })),
  frozen('0016', 'title may contain colon or transition text',
    'Title: CUT TO:\nAuthor: A Writer\nCUT TO:\n\nINT. ROOM - DAY\n\n!Wait.', project => {
      assert.equal(project.title, 'CUT TO:');
      assert.deepEqual(textOf(project), ['CUT TO:', 'Wait.']);
    }),
  // Exact frozen ::0007 input, with corrected expectations for the documented
  // forced-action continuation behavior. This does NOT reproduce its obsolete
  // 1000 ms assertion and is not unchanged-assertion migration credit.
  { id: 'baseline-0007-input:literal-malformed-continuation', name: 'original CI input keeps malformed annotation literal',
    text: '.First empty scene\n\n.Second scene\n\n!Wait.\n[[scriv duration=-1 coverage=99999999999999999999]]', verify(project) {
      assert.deepEqual(titlesOf(project), ['First empty scene', 'Second scene']);
      assert.equal(project.entries.length, 1);
      assert.equal(project.entries[0].kind, 'direction');
      assert.equal(project.entries[0].text, 'Wait.\n[[scriv duration=-1 coverage=99999999999999999999]]');
      assert.equal(project.entries[0].ownedDurationMs, 1500);
      assert.equal(project.entries[0].coverageDurationMs, 1500);
    } },
  // Post-baseline regression: no frozen inventory ID and no retirement credit.
  { id: 'post-baseline:forced-action-literal-continuation', name: 'forced-action timing continuation remains literal',
    text: 'INT. ROOM\n\n!Wait.\n[[scriv duration=2000 coverage=3000]]', verify(project) {
      assert.equal(project.entries.length, 1);
      assert.equal(project.entries[0].kind, 'direction');
      assert.equal(project.entries[0].text, 'Wait.\n[[scriv duration=2000 coverage=3000]]');
      assert.equal(project.entries[0].ownedDurationMs, 1500);
      assert.equal(project.entries[0].coverageDurationMs, 1500);
    } },
];


export const metadataSource = `title:
    First line
    Second line
Credit: Written by
Authors:
    One Writer
    Another Writer
Source: An original story
Draft date: 2026-10-30
Contact:
    Production office
    Address line
Copyright: 2026
Custom metadata: Preserved in the source, not a timed script element

EXT. ROAD - DAY

!The car arrives.`;

export const forcedSource = 'Title: Forced\n\n.A custom scene name\n\n!RUN\nDo not look back.\n\n[[scriv duration=2000 coverage=86400000]]\n\n!INT. is a direction here, not a scene.\n\n[[scriv duration=1000 coverage=1000]]\n\n!@camera stays still\n\n[[scriv duration=0 coverage=3000]]';

export const invalidFilenames = [null, 12, '', '.', '..', '.hidden.fountain', '../outside.fountain', '/outside.fountain', 'a/b.fountain', 'a\\b.fountain', 'file:outside.fountain', 'bad\u0000.fountain', 'bad\n.fountain', 'file.txt', 'a'.repeat(129) + '.fountain'];

export const openingLines = ['JASON: Hello there.', 'Warning: Do not enter.', '12:30 on the clock.', 'https://example.test/script'];
