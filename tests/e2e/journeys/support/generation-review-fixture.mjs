// Serialized synthetic import input, never an installed model setter. The two
// complete one-word dialogue slots avoid copying the production timing engine.
export const people = [
  { id: 'mara', name: 'Mara', aliases: ['Ma', 'まら'], appearance: 'Blue jacket. 👩🏽‍🚀',
    biography: 'Identity history only. cafe\u0301 日本語. '.repeat(30), color: 'blue' },
  { id: 'june', name: 'June', aliases: ['Junie'], appearance: 'Green coat.',
    biography: 'A quiet observer. 👩🏽‍🚀 cafe\u0301', color: 'purple' },
];
export const fixture = {
  schemaVersion: 1, id: 'synthetic-generation-review', title: 'Read-only generation review',
  createdAt: 0, modifiedAt: 0, revision: 0,
  scenes: [{ id: 'scene', title: 'INT. REVIEW — DAY', order: 0 }],
  entries: [
    { id: 'mara-line', sceneId: 'scene', order: 0, kind: 'dialogue', text: '👩🏽‍🚀', characterId: 'mara',
      ownedDurationMs: 4000, coverageDurationMs: 0, color: 'purple',
      words: [{ id: 'mara-word', text: '👩🏽‍🚀', startMs: 0, endMs: 4000 }] },
    { id: 'june-line', sceneId: 'scene', order: 1, kind: 'dialogue', text: 'cafe\u0301', characterId: 'june',
      ownedDurationMs: 4000, coverageDurationMs: 0, color: 'purple',
      words: [{ id: 'june-word', text: 'cafe\u0301', startMs: 0, endMs: 4000 }] },
  ],
  characters: [...people, { id: 'unrelated', name: 'Unrelated sentinel', aliases: [],
    appearance: 'Excluded appearance sentinel', biography: 'Excluded biography sentinel', color: 'blue' }],
  images: [], audioAssets: [], audioClips: [], audioVolume: 1,
  cues: [{ id: 'review-cue', sceneId: 'scene', label: '01A', startMs: 0, endMs: 8000,
    prompt: '', startAnchor: { entryId: 'mara-line', offsetMs: 0 }, authoredDurationMs: 8000 }],
};
