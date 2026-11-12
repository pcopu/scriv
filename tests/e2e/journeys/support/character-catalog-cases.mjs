// Synthetic authored data only. Never reads the user's catalog or clipboard.
export const catalogCases = [
  { group: 'create-find-reopen', id: 'create-find-reopen', interactions: ['CHR-01', 'CHR-02', 'CHR-03', 'CHR-05', 'CHR-06', 'CHR-13', 'CHR-14'],
    oracles: ['blank/whitespace Save eligibility', '201-unit name rejection without mutation', 'clean/reverted cancel', 'save new Unicode name', 'no results and Clear search restoration', 'case-insensitive matching', 'repeated edit reopening without mutation'] },
  { group: 'edit-profile', id: 'edit-profile', interactions: ['CHR-03', 'CHR-05', 'CHR-06', 'CHR-07', 'CHR-13', 'CHR-14'],
    oracles: ['exact name trim/notes whitespace and UTF-16', 'palette opening label multiset', 'draft isolation', 'existing characters and entry/link preservation', '202-unit emoji name rejection', '20001-unit appearance rejection', '12000 U+0001 encoded-size rejection', 'edit/save/reopen/resave', 'clear/restore/repeated clean cancel', 'biography-only and appearance-only Unicode canonical replacement'] },
  { group: 'search-focus', id: 'search-focus', interactions: ['CHR-01', 'CHR-02'],
    oracles: ['fresh sample ribbon identities', 'native search focus and filter', 'exactly one priority Escape command', 'full restoration and resigned focus', 'disabled-afterward eligibility', 'repeat complete search/Escape cycle'] },
];
export const fixtures = {
  invalidASCIIName: 'Q'.repeat(201),
  createdName: 'CLI Validation Zéphyr',
  missingSearch: 'no-such-cli-character-91be77',
  initialProfile: { name: '台詞', biography: '  cafe\u0301\n', appearance: 'Warm light', color: 'F272AC' },
  invalidUnicodeName: '🙂'.repeat(101),
  invalidAppearance: 'x'.repeat(20_001),
  encodedBiography: '\u0001'.repeat(12_000),
};
