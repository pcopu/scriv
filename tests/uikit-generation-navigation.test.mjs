import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

// Portable source contracts, not a substitute for native layout and interaction.
const source = name => readFile(new URL(`../apps/catalyst/ScrivUIKit/Images/${name}.swift`, import.meta.url), 'utf8');

test('Source person links route to the requested People header after layout', async () => {
  const text = await source('GenerationBriefReviewController');
  assert.match(text, /self\?\.showPerson\(person\.id\)/);
  assert.match(text, /generation-source-person-/);
  assert.match(text, /expandedPeople\.insert\(id\)/);
  assert.match(text, /if selectedTab != \.people \|\| !alreadyExpanded \{ select\(\.people\) \}/);
  assert.match(text, /peopleHeaders\[person\.id\] = toggle/);
  assert.match(text, /DispatchQueue\.main\.async/);
  assert.match(text, /scroll\.scrollRectToVisible\(destination, animated: false\)/);
});

test('deferred person reveal cannot revive stale or newer review content', async () => {
  const text = await source('GenerationBriefReviewController');
  const route = text.split('func showPerson(_ id: String) {')[1]?.split('func togglePerson')[0];
  assert.ok(route);
  assert.match(route, /guard isValid, snapshot\.context\.characters\.contains/);
  assert.match(route, /self\.isValid, self\.selectedTab == \.people/);
  assert.match(route, /self\.peopleHeaders\[id\] === target/);
  assert.match(route, /\[weak self, weak target\]/);
  assert.doesNotMatch(route, /store\.|generate|UIPasteboard|\.text =/);
  assert.match(text, /peopleHeaders\.removeAll\(\)/);
});

test('Storyboard selection count uses singular only for exactly one word', async () => {
  const text = await source('StoryboardViewController');
  assert.match(text, /selectionLabel\.text = StoryboardSelectionPresentation\.summary\(wordCount: store\.selectedWordIDs\.count\)/);
  assert.match(text, /guard wordCount > 0 else \{ return "" \}/);
  assert.match(text, /wordCount == 1 \? "word" : "words"/);
});
