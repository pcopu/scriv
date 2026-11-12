import assert from 'node:assert/strict';
import { ScrivSession } from '../../../cli/scriv.mjs';
import { scriptAuthoringSteps, focusedEditors, byID } from './support/script-authoring-steps.mjs';
import { characterCatalogSteps, inspectCreationEntries } from './support/character-catalog-steps.mjs';
import { audioLibrarySteps, sortedProjects } from './support/audio-library-steps.mjs';
import { syntheticPCM, verifyImportedAsset, stableContent, syntheticFilename } from './support/audio-library-fixtures.mjs';
import { lineDurationSteps } from './support/line-duration-steps.mjs';
import { shortFilmContract, film } from './support/short-film-contract.mjs';

const args = process.argv.slice(2);
assert.ok(args.length === 0 || args.length === 1 && args[0] === '--list-cases', 'Use only --list-cases, or run the entire continuous film');
if (args.length) console.log(JSON.stringify(shortFilmContract, null, 2));
else {
  assert.ok(process.env.SCRIV_E2E_APP, 'Set SCRIV_E2E_APP to a matching automation-enabled Catalyst bundle');
  let session = await ScrivSession.launch(process.env.SCRIV_E2E_APP, { persistent: true });
  try { await makeAndReviseFilm(session, next => { session = next; }); } finally { await session.close(); }
}

async function makeAndReviseFilm(session, retainSession) {
  let step = scriptAuthoringSteps(session), ui = audioLibrarySteps(session);
  const catalog = characterCatalogSteps(session), duration = lineDurationSteps(session);
  const capabilities = await session.command('capabilities'), runID = capabilities.runID, root = session.root;
  assert.equal(capabilities.cloudIsolation.network, 'disabled');
  assert.deepEqual(capabilities.workspace, { persistent: true, resumed: false });
  for (const command of ['loaded-project', 'persisted-projects', 'presented-alerts', 'snapshot', 'activate',
    'text', 'type', 'selection', 'key', 'keys', 'select', 'scroll', 'slider', 'toggle', 'menu', 'menu-action',
    'import-local-image', 'local-image-evidence', 'import-audio', 'script-insert', 'script-interaction-counts']) assert.ok(capabilities.commands.includes(command), command);
  assert.ok(capabilities.publicDelegateCommands.includes('script-insert'));
  for (const scope of ['script-scenes', 'layers-direction-duration', 'character-portrait-options']) assert.ok(capabilities.semanticMenuActionScopes.includes(scope), scope);
  for (const command of ['import-local-image', 'import-audio']) assert.ok(capabilities.semanticApplicationCommands.includes(command), command);
  let sentinel, current, originalScene, secondScene, openingID, originalDialogueID, dialogueID, endingID, lastID;
  let cueID, firstImageID, linkedClipID, sceneClipID, confirmedLink, historyPrior;
  const cast = [], completed = [];
  const entry = id => { const found = current.entries.filter(item => item.id === id); assert.equal(found.length, 1); return found[0]; };
  const button = title => node => node.enabled !== undefined && (node.title === title || node.label === title);
  const stable = project => stableContent(project); // Excludes revision and modifiedAt only.
  function spokenWords(words, text, owned) {
    assert.deepEqual(words.map(word => word.text), text.match(/\S+/gu) ?? []);
    assert.equal(new Set(words.map(word => word.id)).size, words.length);
    for (const [index, word] of words.entries()) {
      assert.match(word.id, /^[a-f0-9-]{36}$/i);
      assert.ok(Number.isSafeInteger(word.startMs) && Number.isSafeInteger(word.endMs));
      assert.ok(word.startMs >= 0 && word.endMs > word.startMs && word.endMs <= owned);
      if (index) assert.ok(word.startMs >= words[index - 1].endMs);
    }
  }

  async function packages() {
    const all = sortedProjects(await session.command('persisted-projects'));
    assert.deepEqual(all, sortedProjects([sentinel, current]), 'The entire unrelated sentinel and every authored field remain exact');
  }
  async function checkpoint() {
    await step.workspaceCommand('s');
    await step.saved(project => project.id === current.id && project.revision === current.revision);
    assert.deepEqual((await session.command('loaded-project')).project, current);
    await packages(); assert.deepEqual(await session.command('presented-alerts'), []);
    assert.equal(session.root, root); assert.equal((await session.command('capabilities')).runID, runID);
  }
  async function chapter(name, work) {
    assert.equal(name, shortFilmContract.chapters[completed.length], 'Ordered chapters cannot skip or reset prior work');
    try { await work(); await checkpoint(); }
    catch (error) { throw new Error(`FILM-J01/${name} failed after ${completed.length} complete chapters; no mutation retry or later chapter`, { cause: error }); }
    completed.push(name); console.log(`PASS FILM-J01 chapter: ${name}`);
  }
  async function mutation(before, predicate, expected, revisionDelta = 1) {
    const after = await step.saved(project => project.id === before.id && project.revision > before.revision && predicate(project));
    assert.equal(after.revision, before.revision + revisionDelta, 'Exactly the intended accepted mutations, without hidden edits');
    assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt >= before.modifiedAt);
    assert.deepEqual(stable(after), stable(expected(after)), 'Only explicitly expected content changes are accepted');
    current = after; await packages(); return after;
  }
  async function exactChange(change, predicate = () => true) {
    const before = current, expected = structuredClone(before); change(expected);
    return mutation(before, predicate, () => expected);
  }
  async function beginSelected(id) {
    await step.key('\r', ['command']);
    let nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1 && focusedEditors(nodes)[0].identifier === `script-editor-${id}`);
    await step.reveal(focusedEditors(nodes)[0], nodes);
    await session.waitFor(nodes => byID(nodes, `script-editor-${id}`).some(node => node.hittable && node.firstResponder));
    return `script-editor-${id}`;
  }
  async function replaceSelected(id, text) {
    const before = current, old = entry(id), target = await beginSelected(id);
    await session.command('text', { target, text }); await step.waitEditor(target, text, text.length);
    await step.finishEditor(); await step.displayed(id, text, { finished: true });
    return mutation(before, project => project.entries.find(item => item.id === id)?.text === text, after => {
      const actual = after.entries.find(item => item.id === id);
      assert.equal(actual.ownedDurationMs, old.ownedDurationMs, 'Short edits preserve owned duration');
      assert.deepEqual(actual.words.map(word => word.text), old.kind === 'direction' ? [] : text.match(/\S+/gu) ?? []);
      for (const link of actual.characterLinks ?? []) {
        assert.equal(text.slice(link.location, link.location + link.length), link.text);
        assert.ok(cast.some(character => character.id === link.characterId)); assert.equal(link.isConfirmed, false);
      }
      return { ...before, entries: before.entries.map(item => item.id === id
        ? { ...item, text, words: actual.words, characterLinks: actual.characterLinks } : item) };
    });
  }
  async function followPlayback() {
    // Scope the real switch to the footer containing the literal label.
    const nodes = await session.waitFor(nodes => nodes.some(node => node.text === 'Follow playback'));
    const labels = nodes.filter(node => node.text === 'Follow playback'); assert.equal(labels.length, 1);
    const parent = labels[0].path.slice(0, labels[0].path.lastIndexOf('.'));
    const switches = nodes.filter(node => node.path.startsWith(parent + '.') && typeof node.isOn === 'boolean');
    assert.equal(switches.length, 1); assert.ok(switches[0].enabled && switches[0].hittable);
    if (!switches[0].isOn) await session.command('toggle', { target: switches[0].path, value: true });
    await session.waitFor(nodes => nodes.some(node => node.path === switches[0].path && node.isOn === true));
  }
  async function selectDialogue(id) {
    await step.selectTab('Script'); await followPlayback();
    const target = entry(id); assert.equal(target.kind, 'dialogue');
    const ordered = current.entries.filter(item => item.sceneId === target.sceneId).sort((a, b) => a.order - b.order || a.id.localeCompare(b.id));
    const start = ordered.slice(0, ordered.findIndex(item => item.id === id)).reduce((sum, item) => sum + item.ownedDurationMs, 0);
    await selectFilmPlaybackPosition(session, ui, start + Math.min(100, target.ownedDurationMs / 2));
    // beginSelected verifies that the app, rather than our arithmetic alone,
    // selected the intended dialogue before any text is changed.
  }
  async function sceneAction(from, action) {
    await step.selectTab('Script'); const editors = focusedEditors(await session.command('snapshot')); assert.ok(editors.length <= 1); if (editors.length) await step.finishEditor();
    const control = await ui.reveal(node => /UIButton$/.test(node.type) && node.title === `${from.title} ⌄`);
    const menu = await session.command('menu', { target: control.path });
    assert.equal(menu.primary.length, 1);
    const choices = menu.primary[0].children.filter(item => item.title === action && !item.disabled && !item.hidden);
    assert.equal(choices.length, 1, 'Never guess among duplicate scene/menu titles');
    assert.deepEqual(await session.command('menu-action', { target: control.path, scope: 'script-scenes', action }),
      { dispatched: true, coverage: 'semantic-menu-action' });
    const title = action === 'New scene' ? 'INT. NEW SCENE — DAY' : action;
    await session.waitFor(nodes => nodes.some(node => node.title === `${title} ⌄`));
  }
  async function imageEvidence() {
    for (let attempt = 0; attempt < 60; attempt++) {
      let result;
      try { result = await session.command('local-image-evidence'); }
      catch (error) {
        assert.match(error.message, /local-image-evidence: Local image evidence is unavailable or inconsistent\.?$/);
        if (attempt === 59) throw error;
        await new Promise(resolve => setTimeout(resolve, 100)); continue;
      }
      assert.equal(result.projectID, current.id); assert.equal(result.generationJobCount, 0); assert.equal(result.analysisScanning, false);
      assert.equal(result.assets.length, 2);
      for (const [index, asset] of current.images.entries()) {
        const observed = result.assets.find(item => item.assetID === asset.id); assert.ok(observed);
        assert.equal(observed.sha256, film.imageHashes[index]); assert.equal(observed.byteCount, 73);
        assert.equal(observed.decoded, true); assert.equal(observed.width, 2); assert.equal(observed.height, 2);
      }
      if (result.assets.find(item => item.assetID === firstImageID).visiblePreviewCount > 0) return;
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.fail('The chosen historical image never became visibly decoded');
  }

  await chapter('create-project-and-preserve-sentinel', async () => {
    await step.selectTab('Script'); await step.workspaceCommand('s');
    sentinel = await step.saved(project => project.title === 'YAM MAN');
    assert.deepEqual(await session.command('persisted-projects'), [sentinel], 'Start only in isolated synthetic storage');
    await ui.activate(node => node.identifier === 'workspace-project');
    await ui.reveal(node => node.placeholder === 'Find a project'); await ui.activate(button('New project'));
    current = await step.saved(project => project.id !== sentinel.id);
    assert.equal(current.title, 'Untitled'); assert.equal(current.scenes.length, 1);
    assert.deepEqual(current.entries.map(item => item.text), ['Describe the opening moment.', 'Your first line.']);
    assert.deepEqual(current.characters, []); assert.deepEqual(current.images, []); assert.deepEqual(current.audioClips, []);
    assert.equal(current.cues.length, 1); assert.equal(current.cues[0].label, '01A');
    originalScene = current.scenes[0]; openingID = current.entries[0].id; originalDialogueID = current.entries[1].id; cueID = current.cues[0].id;
    if ((await session.command('snapshot')).some(node => node.placeholder === 'Find a project')) await ui.activate(button('Close Projects'));
    await step.selectTab('Script');
    await replaceSelected(openingID, film.opening); // install(.blank()) selects this first entry.
  });

  await chapter('create-cast-and-write-opening', async () => {
    await catalog.openCatalog();
    for (const profile of film.cast) {
      const before = current;
      // The empty catalog has a second, text-title Add character button.
      // Select the unique header icon control rather than an ambiguous label.
      await ui.activate(node => node.label === 'Add character' && !node.title && node.enabled !== undefined);
      await catalog.saveEnabled(false);
      await catalog.text(catalog.nameField, profile.name); await catalog.text(catalog.biographyField, profile.biography);
      await catalog.text(catalog.appearanceField, profile.appearance); await selectStandardSwatch(session, catalog, profile.swatch);
      await catalog.saveEditor();
      await mutation(before, project => project.characters.length === before.characters.length + 1, after => {
        const character = after.characters.find(item => !before.characters.some(old => old.id === item.id)); assert.ok(character);
        assert.match(character.id, /^[a-f0-9-]{36}$/i);
        const { swatch, ...fields } = profile;
        assert.deepEqual(character, { id: character.id, aliases: [], ...fields }); cast.push(character);
        inspectCreationEntries(before.entries, after.entries, before.characters);
        return { ...before, characters: [...before.characters, character], entries: after.entries };
      });
    }
    await catalog.text(catalog.searchField, 'missing lantern keeper');
    await session.waitFor(nodes => nodes.some(node => node.text === 'No matching characters'));
    await catalog.activate('Clear search');
    await selectDialogue(originalDialogueID); await replaceSelected(originalDialogueID, film.firstLine);
    const openingLinks = entry(originalDialogueID).characterLinks;
    assert.equal(openingLinks.length, 1); assert.match(openingLinks[0].id, /^[a-f0-9-]{36}$/i);
    assert.deepEqual(openingLinks[0], { id: openingLinks[0].id, characterId: cast[0].id, location: 0, length: 3, text: 'Ada', isConfirmed: false });
  });

  await chapter('revise-source-and-confirm-identity', async () => {
    const before = current, context = await step.addDialogue(before);
    dialogueID = context.entryID;
    const addedEntry = context.added.entries.find(item => item.id === dialogueID);
    assert.equal(addedEntry.text, 'New line'); assert.equal(addedEntry.sceneId, originalScene.id);
    assert.equal(addedEntry.kind, 'dialogue'); assert.equal(addedEntry.order, 2);
    assert.equal(addedEntry.ownedDurationMs, 3000); assert.equal(addedEntry.characterId, cast[0].id);
    spokenWords(addedEntry.words, 'New line', 3000);
    assert.deepEqual(addedEntry, { id: dialogueID, sceneId: originalScene.id, order: 2, kind: 'dialogue', text: 'New line',
      characterId: cast[0].id, ownedDurationMs: 3000, coverageDurationMs: 0, color: 'purple', words: addedEntry.words });
    assert.deepEqual(stable(context.added), stable({ ...before, entries: [...before.entries, addedEntry],
      cues: before.cues.map(cue => cue.id === cueID ? { ...cue, startAnchor: { entryId: originalDialogueID, offsetMs: 0 }, authoredDurationMs: 3000 } : cue) }),
    'Adding the selected dialogue materializes the original cue anchor and preserves every other field');
    await session.command('text', { target: context.editor.identifier, text: film.draftLine });
    await step.waitEditor(context.editor.identifier, film.draftLine, film.draftLine.length);
    const start = film.draftLine.indexOf('cafe\u0301');
    await session.command('selection', { target: context.editor.identifier, start, end: start + 'cafe\u0301'.length });
    await step.waitEditor(context.editor.identifier, film.draftLine, start, start + 'cafe\u0301'.length);
    await session.command('type', { target: context.editor.identifier, text: 'café' });
    await step.waitEditor(context.editor.identifier, film.revisedLine, start + 'café'.length);
    await step.finishEditor(); await step.displayed(dialogueID, film.revisedLine, { finished: true });
    current = await step.saved(project => project.id === before.id && project.entries.find(item => item.id === dialogueID)?.text === film.revisedLine);
    assert.ok(current.revision >= context.added.revision + 1 && current.revision <= context.added.revision + 2,
      'The two edits in one mounted editor may coalesce, but cannot create unrelated revisions');
    assert.equal(current.entries.length, before.entries.length + 1);
    assert.deepEqual(current.characters, before.characters); assert.deepEqual(current.images, before.images);
    for (const old of before.entries) assert.equal(entry(old.id).text, old.text);
    const authored = entry(dialogueID);
    assert.equal(authored.sceneId, originalScene.id); assert.equal(authored.characterId, cast[0].id);
    assert.equal(authored.kind, 'dialogue'); assert.equal(authored.ownedDurationMs, 3000);
    spokenWords(authored.words, film.revisedLine, 3000);
    assert.equal(authored.characterLinks.length, 1);
    const proposed = authored.characterLinks[0];
    assert.match(proposed.id, /^[a-f0-9-]{36}$/i);
    assert.deepEqual(proposed, { id: proposed.id, characterId: cast[0].id, location: 3, length: 3, text: 'Ada', isConfirmed: false });
    assert.deepEqual(stable(current), stable({ ...context.added, entries: context.added.entries.map(item => item.id === dialogueID
      ? { ...item, text: film.revisedLine, words: authored.words, characterLinks: [proposed] } : item) }),
    'Authoring changes only the new dialogue text, words and exact character suggestion');
    // The original line also mentions Ada. Scope Review to this entry's row.
    let nodes = await session.waitFor(nodes => byID(nodes, `script-line-${dialogueID}`).length === 1);
    await step.reveal(byID(nodes, `script-line-${dialogueID}`)[0], nodes);
    nodes = await session.waitFor(nodes => byID(nodes, `script-line-${dialogueID}`).some(node => node.hittable));
    const line = byID(nodes, `script-line-${dialogueID}`)[0];
    const row = nodes.filter(node => /ScriptEntryRow$/.test(node.type) && line.path.startsWith(node.path + '.')).sort((a, b) => b.path.length - a.path.length)[0];
    assert.ok(row);
    await ui.activate(node => node.path.startsWith(row.path + '.') && node.title === 'Review 1 character suggestion');
    const source = await session.waitFor(nodes => nodes.some(node => node.label === 'Source line, unchanged') && nodes.filter(button('Save links')).length === 1 && nodes.find(button('Save links')).enabled === true);
    assert.equal(source.find(node => node.label === 'Source line, unchanged').text, film.revisedLine);
    await ui.activate(button('Confirm')); await packages();
    await ui.activate(button('Save links'));
    confirmedLink = { ...proposed, isConfirmed: true };
    await exactChange(project => { project.entries.find(item => item.id === dialogueID).characterLinks = [confirmedLink]; },
      project => project.entries.find(item => item.id === dialogueID)?.characterLinks?.[0]?.isConfirmed);
    await session.waitFor(nodes => !nodes.some(node => node.label === 'Source line, unchanged'));
  });

  await chapter('import-revise-and-tag-picture', async () => {
    // Seek the existing 01A cue rather than implicitly creating a second cue.
    await selectFilmPlaybackPosition(session, ui, current.cues.find(item => item.id === cueID).startMs);
    for (const [index, fixture] of ['coral', 'blue'].entries()) {
      const before = current;
      assert.deepEqual(await session.command('import-local-image', { fixture }, 30000), { dispatched: true, imported: true, cleanupVerified: true });
      await mutation(before, project => project.images.length === index + 1, after => {
        const asset = after.images[index]; assert.match(asset.id, /^[a-f0-9-]{36}$/i); assert.ok(Number.isFinite(asset.createdAt));
        assert.deepEqual(asset, { id: asset.id, version: index + 1, fileName: film.imageHashes[index] + '.png', sha256: film.imageHashes[index],
          mimeType: 'image/png', byteCount: 73, characterIds: [], prompt: 'Imported image', createdAt: asset.createdAt,
          ...(index ? { previousVersionId: firstImageID } : {}) });
        if (!index) firstImageID = asset.id;
        return { ...before, images: [...before.images, asset], cues: before.cues.map(cue => cue.id === cueID ? { ...cue, imageId: asset.id } : cue) };
      });
    }
    await ui.activate(node => node.identifier === 'preview-version');
    const picker = await session.waitFor(nodes => nodes.some(node => node.identifier === 'image-picker-use-selection'));
    const historical = picker.filter(node => node.label?.includes('\nVersion 1') && /Cell/.test(node.type) && node.hittable);
    assert.equal(historical.length, 1);
    await session.command('activate', { target: historical[0].path });
    await ui.activate(node => node.identifier === 'image-picker-use-selection');
    await exactChange(project => { project.cues.find(cue => cue.id === cueID).imageId = firstImageID; });
    await session.waitFor(nodes => !nodes.some(node => node.identifier === 'image-picker-use-selection'));
    await ui.activate(node => node.label === 'Edit pictured character tags' && node.enabled !== undefined);
    for (const [index, character] of cast.entries()) {
      await ui.activate(node => node.label === character.name && node.enabled !== undefined);
      await exactChange(project => { project.images[0].characterIds = cast.slice(0, index + 1).map(item => item.id).sort(); });
      await session.waitFor(nodes => nodes.some(node => node.label === character.name && node.value === 'Pictured in this image'));
    }
    await ui.activate(button('Done')); await session.waitFor(nodes => nodes.some(node => node.identifier === 'preview-inspect' && node.hittable));
    await imageEvidence();
  });

  await chapter('choose-and-restore-character-portraits', async () => {
    const secondImageID = current.images[1].id;
    const target = 'character-portrait-options', scope = target;
    async function choosePicture(version, imageID) {
      await ui.activate(node => node.identifier === 'preview-version');
      const picker = await session.waitFor(nodes => nodes.some(node => node.identifier === 'image-picker-use-selection'));
      const choices = picker.filter(node => node.label?.includes(`\nVersion ${version}`) && /Cell/.test(node.type) && node.hittable);
      assert.equal(choices.length, 1);
      await session.command('activate', { target: choices[0].path }); await ui.activate(node => node.identifier === 'image-picker-use-selection');
      await exactChange(project => { project.cues.find(cue => cue.id === cueID).imageId = imageID; });
      await session.waitFor(nodes => !nodes.some(node => node.identifier === 'image-picker-use-selection'));
    }
    async function selectCast(index) {
      await catalog.openCatalog({ persist: false }); await catalog.text(catalog.searchField, '');
      await ui.activate(node => node.identifier === `character-ribbon-${cast[index].id}`);
      await session.command('end-editing');
      await session.waitFor(nodes => {
        const controls = nodes.filter(node => node.identifier === target);
        if (controls.length !== 1) return false;
        const details = controls[0].path.slice(0, controls[0].path.lastIndexOf('.')) + '.';
        return nodes.some(node => node.path.startsWith(details) && node.text === cast[index].name);
      });
      await ui.reveal(node => node.identifier === target);
    }
    async function refuse(parameters) {
      const unchanged = await session.command('loaded-project');
      await assert.rejects(session.command('menu-action', { target, scope, ...parameters }),
        /menu-action: Character portrait action is outside the supported isolated scope/);
      assert.deepEqual(await session.command('loaded-project'), unchanged); await packages();
      assert.deepEqual(await session.command('presented-alerts'), []);
    }
    async function portrait(index, imageID, title, remove = false) {
      await selectCast(index);
      const character = cast[index], before = current, witness = await session.command('loaded-project');
      const menu = await session.command('menu', { target });
      assert.deepEqual(menu.secondary, []); assert.deepEqual(menu.context, []); assert.equal(menu.primary.length, 1);
      const sections = menu.primary[0].children;
      assert.equal(sections.length, character.portraitImageId ? 2 : 1);
      const choices = (remove ? sections[1] : sections[0]).children.filter(action => action.title === title);
      assert.equal(choices.length, 1); assert.equal(choices[0].disabled, false); assert.equal(choices[0].hidden, false);
      assert.equal(choices[0].state, !remove && character.portraitImageId === imageID ? 'on' : 'off');
      assert.deepEqual(await session.command('menu-action', { target, scope, action: title, characterID: character.id, imageID }),
        { dispatched: true, coverage: 'semantic-menu-action' });
      if (!remove && character.portraitImageId === imageID) {
        assert.deepEqual(await session.command('loaded-project'), witness, 'Reselecting the stored portrait does not create a revision or change Date bits');
        await packages();
      } else {
        await exactChange(project => {
          const record = project.characters.find(item => item.id === character.id);
          if (remove) delete record.portraitImageId; else record.portraitImageId = imageID;
        }, project => project.characters.find(item => item.id === character.id).portraitImageId === (remove ? undefined : imageID));
        cast[index] = current.characters.find(item => item.id === character.id);
      }
      const dates = (await session.command('loaded-project')).dateReferenceTimeBits;
      assert.equal(dates.createdAt, witness.dateReferenceTimeBits.createdAt);
      assert.deepEqual(dates.images, witness.dateReferenceTimeBits.images, 'Portrait changes preserve every immutable image Date bit');
      assert.deepEqual(current.entries, before.entries); assert.deepEqual(current.images, before.images);
      assert.deepEqual(current.cues, before.cues, 'Choosing/removing portraits never retargets the film’s picture cue');
      assert.deepEqual(entry(dialogueID).characterLinks, [confirmedLink]);
      // Removing the stored choice can still display the app's first-tagged-image fallback.
      await session.waitFor(nodes => nodes.some(node => node.text === (remove ? 'No portrait yet' :
        `Portrait from ${imageID === firstImageID ? '01A' : 'image'} · v${imageID === firstImageID ? 1 : 2}`)));
    }
    await selectCast(0);
    await refuse({ action: 'Use 01A · v1', characterID: cast[0].id, imageID: secondImageID }); // Untagged version cannot borrow another action.
    await refuse({ action: 'Use 01A · v1', characterID: cast[1].id, imageID: firstImageID }); // Wrong rendered character.
    await refuse({ action: 'Remove portrait', characterID: cast[0].id, imageID: firstImageID }); // No stored portrait exists yet.
    await refuse({ action: 'Use 01A · v1', characterID: cast[0].id, imageID: firstImageID, unexpected: true });
    await step.selectTab('Script'); await choosePicture(2, secondImageID);
    await ui.activate(node => node.label === 'Edit pictured character tags' && node.enabled !== undefined);
    await ui.activate(node => node.label === cast[0].name && node.enabled !== undefined);
    await exactChange(project => { project.images[1].characterIds = [cast[0].id]; });
    await ui.activate(button('Done')); await session.waitFor(nodes => nodes.some(node => node.identifier === 'preview-inspect' && node.hittable));
    await choosePicture(1, firstImageID);
    await portrait(0, secondImageID, 'Use Image · v2');
    await portrait(0, secondImageID, 'Use Ada portrait · v2'); // Observe the rebuilt current-title action, not a cached path/title.
    await refuse({ action: 'Remove portrait', characterID: cast[0].id, imageID: firstImageID }); // Stale/wrong removal identity.
    await portrait(0, secondImageID, 'Remove portrait', true);
    await portrait(0, secondImageID, 'Use Image · v2');
    await portrait(1, firstImageID, 'Use 01A · v1');
    assert.equal(cast[0].portraitImageId, secondImageID); assert.equal(cast[1].portraitImageId, firstImageID);
    assert.equal(current.cues.find(cue => cue.id === cueID).imageId, firstImageID);
    await step.selectTab('Script'); await imageEvidence();
  });

  await chapter('attach-trim-and-mix-audio', async () => {
    await selectDialogue(dialogueID);
    // Open/finish the actual selected editor to prove the selected attachment.
    await beginSelected(dialogueID); await step.finishEditor();
    async function importClip(attachment, silence) {
      const before = current, bytes = syntheticPCM({ silence });
      const slider = await ui.reveal(node => node.identifier === 'scene-playback-position');
      const playhead = slider.slider.value;
      assert.deepEqual(await session.command('import-audio', { base64: bytes.toString('base64'), attachment }, 30000),
        { dispatched: true, imported: true, cleanupVerified: true });
      await mutation(before, project => project.audioClips.length === before.audioClips.length + 1, after => {
        const asset = after.audioAssets.at(-1), clip = after.audioClips.at(-1); verifyImportedAsset(asset, bytes, { silence });
        assert.match(clip.id, /^[a-f0-9-]{36}$/i);
        const expected = { id: clip.id, sceneId: originalScene.id, assetId: asset.id, startMs: attachment === 'scene' ? Math.trunc(playhead) : 0,
          sourceStartMs: 0, durationMs: attachment === 'scene' ? 4000 : 3000, volume: 1, isMuted: false,
          ...(attachment === 'selected-dialogue' ? { entryId: dialogueID } : {}) };
        assert.deepEqual(clip, expected);
        if (attachment === 'scene') sceneClipID = clip.id; else linkedClipID = clip.id;
        return { ...before, audioAssets: [...before.audioAssets, asset], audioClips: [...before.audioClips, expected] };
      });
    }
    await importClip('selected-dialogue', false);
    await ui.openLibrary();
    const linked = current.audioClips.find(clip => clip.id === linkedClipID);
    await ui.openTrim(linked, ['0.000', '3.000', '0.000']); await ui.draft('0.500', '2.000', '0.250');
    await packages(); await ui.finishTrim(false); await packages();
    await ui.openTrim(linked, ['0.000', '3.000', '0.000']); await ui.draft('0.500', '2.000', '0.250'); await ui.finishTrim();
    await exactChange(project => Object.assign(project.audioClips.find(clip => clip.id === linkedClipID), { sourceStartMs: 500, durationMs: 2000, startMs: 250 }));
    await ui.slider('Clip volume for ' + syntheticFilename, 0.375);
    await exactChange(project => { project.audioClips[0].volume = 0.375; });
    for (const muted of [true, false]) {
      await ui.activate(node => node.label === (muted ? 'Mute ' : 'Unmute ') + syntheticFilename && node.enabled !== undefined);
      await exactChange(project => { project.audioClips[0].isMuted = muted; });
    }
    await ui.closeLibrary();
    await selectFilmPlaybackPosition(session, ui, 0); await importClip('scene', true);
    await ui.slider('Local audio volume', 0.25); await exactChange(project => { project.audioVolume = 0.25; });
    // Subsequent source edit must retain confirmed identity and both audio clips.
    await selectDialogue(dialogueID); const before = current, target = await beginSelected(dialogueID);
    await session.command('selection', { target, start: film.revisedLine.length, end: film.revisedLine.length });
    await step.waitEditor(target, film.revisedLine, film.revisedLine.length);
    const callbacks = await session.command('script-interaction-counts');
    assert.deepEqual(await session.command('script-insert', { target, text: ' Ready.' }),
      { dispatched: true, delegateAcceptedInsertion: true, coverage: 'public-script-insertion-delegate-contract' });
    const afterCallbacks = await session.command('script-interaction-counts');
    assert.equal(afterCallbacks.onTextEditInvocations - callbacks.onTextEditInvocations, 1);
    assert.equal(afterCallbacks.mergeAtStartInvocations, callbacks.mergeAtStartInvocations);
    await step.waitEditor(target, film.revisedLine + ' Ready.', (film.revisedLine + ' Ready.').length);
    await step.finishEditor();
    await mutation(before, project => project.entries.find(item => item.id === dialogueID)?.text === film.revisedLine + ' Ready.', after => {
      const revised = after.entries.find(item => item.id === dialogueID);
      assert.deepEqual(revised.characterLinks, [confirmedLink]); assert.deepEqual(revised.words.map(word => word.text), ['🎬', 'Ada', 'waits', 'by', 'the', 'café.', 'Ready.']);
      assert.deepEqual(revised.words.slice(0, 6).map(word => word.id), entry(dialogueID).words.map(word => word.id));
      return { ...before, entries: before.entries.map(item => item.id === dialogueID ? { ...item, text: film.revisedLine + ' Ready.', words: revised.words } : item) };
    });
  });

  await chapter('create-second-scene-and-adjust-timing', async () => {
    const before = current; await sceneAction(originalScene, 'New scene');
    await mutation(before, project => project.scenes.length === 2, after => {
      secondScene = after.scenes.find(scene => scene.id !== originalScene.id);
      assert.deepEqual(secondScene, { id: secondScene.id, title: 'INT. NEW SCENE — DAY', order: originalScene.order + 1 });
      return { ...before, scenes: [...before.scenes, secondScene] };
    });
    const beforeDirection = current; await step.activate('Add direction');
    let nodes = await session.waitFor(nodes => focusedEditors(nodes).length === 1), editor = focusedEditors(nodes)[0];
    endingID = editor.identifier.slice('script-editor-'.length); await step.reveal(editor, nodes);
    await session.command('text', { target: editor.identifier, text: film.ending }); await step.finishEditor();
    await mutation(beforeDirection, project => project.entries.some(item => item.id === endingID && item.text === film.ending), () => ({ ...beforeDirection,
      entries: [...beforeDirection.entries, { id: endingID, sceneId: secondScene.id, order: 0, kind: 'direction', text: film.ending,
        ownedDurationMs: 0, coverageDurationMs: 3000, color: 'purple', words: [], characterLinks: [] }] }), 2);
    await duration.open(current, endingID, '0.000'); await duration.input('6.000'); await duration.button('Cancel'); await duration.closed();
    assert.deepEqual((await session.command('loaded-project')).project, current); await packages();
    await duration.open(current, endingID, '0.000'); await duration.input('6.000'); await duration.button('Apply'); await duration.closed();
    await exactChange(project => Object.assign(project.entries.find(item => item.id === endingID), { ownedDurationMs: 6000, coverageDurationMs: 9000 }));
    await duration.collapseLayers();
    const beforeDialogue = current, context = await step.addDialogue(current); lastID = context.entryID;
    const secondCue = context.added.cues.find(cue => cue.sceneId === secondScene.id);
    assert.ok(secondCue); assert.match(secondCue.id, /^[a-f0-9-]{36}$/i);
    assert.deepEqual(secondCue, { id: secondCue.id, sceneId: secondScene.id, label: '01A', startMs: 0, endMs: 9000, prompt: '',
      startAnchor: { entryId: endingID, offsetMs: 0 }, authoredDurationMs: 9000 });
    const added = context.added.entries.find(item => item.id === lastID);
    assert.equal(added.text, 'New line'); assert.equal(added.order, 1); assert.equal(added.kind, 'dialogue');
    assert.equal(added.sceneId, secondScene.id); assert.equal(added.characterId, cast[0].id); assert.equal(added.ownedDurationMs, 3000);
    spokenWords(added.words, 'New line', 3000);
    assert.deepEqual(added, { id: lastID, sceneId: secondScene.id, order: 1, kind: 'dialogue', text: 'New line', characterId: cast[0].id,
      ownedDurationMs: 3000, coverageDurationMs: 0, color: 'purple', words: added.words });
    assert.deepEqual(stable(context.added), stable({ ...beforeDialogue,
      entries: [...beforeDialogue.entries.map(item => item.id === endingID ? { ...item, coverageDurationMs: 12000 } : item), added],
      cues: [...beforeDialogue.cues, secondCue] }), 'A new timed dialogue extends forward coverage and creates this scene’s first cue');
    await session.command('text', { target: context.editor.identifier, text: film.lastLine }); await step.finishEditor();
    current = await step.saved(project => project.id === beforeDialogue.id && project.entries.find(item => item.id === lastID)?.text === film.lastLine);
    assert.equal(current.revision, context.added.revision + 1);
    assert.equal(current.entries.length, beforeDialogue.entries.length + 1);
    assert.equal(entry(lastID).sceneId, secondScene.id); assert.equal(entry(lastID).kind, 'dialogue');
    assert.deepEqual(entry(lastID).words.map(word => word.text), ['Béa,', 'bring', 'the', 'lantern', 'home.']);
    assert.deepEqual(entry(lastID).characterLinks.map(({ id, ...link }) => link), [{ characterId: cast[1].id, location: 0, length: 3, text: 'Béa', isConfirmed: false }]);
    assert.deepEqual(stable(current), stable({ ...context.added, entries: context.added.entries.map(item => item.id === lastID
      ? { ...item, text: film.lastLine, words: entry(lastID).words, characterLinks: entry(lastID).characterLinks } : item) }),
    'The final dialogue edit changes nothing outside its source, words and explicit suggestion');
  });

  await chapter('rename-linked-cast-without-rewriting-film', async () => {
    const before = current, original = cast[0], revised = { ...original, ...film.revisedCast };
    assert.ok(before.entries.every(item => Array.isArray(item.characterLinks)),
      'All authored source annotations are explicit before changing the catalog');
    assert.equal(confirmedLink.text, original.name);
    assert.notEqual(revised.name, original.name);
    async function reopen(expected) {
      await catalog.openCatalog({ persist: false });
      await catalog.text(catalog.searchField, expected.name);
      await session.waitFor(nodes => {
        const ribbons = nodes.filter(node => node.identifier?.startsWith('character-ribbon-'));
        return ribbons.length === 1 && ribbons[0].identifier === `character-ribbon-${original.id}` && ribbons[0].label === expected.name;
      });
      await ui.activate(node => node.identifier === `character-ribbon-${original.id}`);
      await catalog.activate('Edit'); await catalog.rememberOpeningPalette(); await catalog.inspectEditor(expected);
    }
    // Restore every changed draft field before Cancel. This is a clean editor
    // dismissal, never a claim that the blocked discard alert was activated.
    await reopen(original);
    await catalog.text(catalog.nameField, revised.name);
    await catalog.text(catalog.biographyField, revised.biography);
    await catalog.text(catalog.appearanceField, revised.appearance);
    await catalog.activate('Orange character colour'); await catalog.inspectEditor(revised); await packages();
    await catalog.text(catalog.nameField, original.name);
    await catalog.text(catalog.biographyField, original.biography);
    await catalog.text(catalog.appearanceField, original.appearance);
    await catalog.activate('Purple character colour'); await catalog.inspectEditor(original);
    await catalog.cancelCleanEditor();
    assert.deepEqual((await session.command('loaded-project')).project, before); await packages();
    assert.deepEqual(await session.command('presented-alerts'), []);

    await reopen(original);
    await catalog.text(catalog.nameField, `  ${revised.name}  `);
    await catalog.text(catalog.biographyField, revised.biography);
    await catalog.text(catalog.appearanceField, revised.appearance);
    await catalog.activate('Orange character colour');
    await catalog.inspectEditor({ ...revised, name: `  ${revised.name}  ` }); await packages();
    await catalog.saveEditor();
    await exactChange(project => { project.characters[0] = revised; }, project => project.characters[0].name === revised.name);
    cast[0] = revised;
    assert.deepEqual(current.entries, before.entries, 'Rename preserves every source byte, word ID, speaker ID and explicit source link');
    assert.deepEqual(entry(dialogueID).characterLinks, [confirmedLink], 'The old wording Ada stays confirmed to the same renamed character ID');
    assert.deepEqual(current.images, before.images, 'Image tags remain character IDs, not copies of renamed display text');
    assert.deepEqual(current.audioClips, before.audioClips, 'Dialogue and scene audio attachments survive catalog revision');
    await reopen(revised); await catalog.cancelCleanEditor(); await packages();
    await catalog.text(catalog.searchField, '');
    await sceneAction(secondScene, originalScene.title);
    await selectFilmPlaybackPosition(session, ui, current.cues.find(cue => cue.id === cueID).startMs);
    await ui.activate(node => node.label === 'Edit pictured character tags' && node.enabled !== undefined);
    const tags = await session.waitFor(nodes => cast.every(character => nodes.some(node =>
      node.label === character.name && node.enabled === true && node.value === 'Pictured in this image')));
    const tagHeadings = tags.filter(node => node.text === 'Who is pictured?'); assert.equal(tagHeadings.length, 1);
    const tagContent = tagHeadings[0].path.slice(0, tagHeadings[0].path.lastIndexOf('.')) + '.';
    assert.ok(!tags.some(node => node.path.startsWith(tagContent) && node.label === original.name && node.enabled !== undefined),
      'Tag sheet resolves the current character name');
    for (const character of cast) {
      const tag = await ui.reveal(node => node.label === character.name && node.enabled !== undefined);
      assert.equal(tag.value, 'Pictured in this image');
      const row = tag.path.slice(0, tag.path.lastIndexOf('.')) + '.';
      assert.ok((await session.command('snapshot')).some(node => node.path.startsWith(row) && node.text === character.name),
        'The reachable tag row has the current character’s actual displayed name');
    }
    await ui.activate(button('Done')); await session.waitFor(nodes => nodes.some(node => node.identifier === 'preview-inspect' && node.hittable));
    assert.deepEqual((await session.command('loaded-project')).project, current); await packages();
    await sceneAction(originalScene, secondScene.title);
  });

  await chapter('play-find-and-review-history', async () => {
    const unchanged = await session.command('loaded-project');
    async function playPause(expectedDuration) {
      await selectFilmPlaybackPosition(session, ui, 0); await ui.activate(button('Play scene'));
      await session.waitFor(nodes => nodes.some(button('Pause scene')) && nodes.some(node => node.identifier === 'scene-playback-position' && node.slider.value > 50));
      await ui.activate(button('Pause scene'));
      let seek = await ui.reveal(node => node.identifier === 'scene-playback-position'); const paused = seek.slider.value;
      await new Promise(resolve => setTimeout(resolve, 150)); seek = await ui.reveal(node => node.identifier === 'scene-playback-position');
      assert.ok(Math.abs(seek.slider.value - paused) < 2); assert.equal(seek.slider.maximum, expectedDuration);
      assert.deepEqual(await session.command('loaded-project'), unchanged);
    }
    // Exercise the scene containing imported audio as well as the later scene.
    // Observed clock/control behavior is not a claim about audible output.
    await sceneAction(secondScene, originalScene.title); await playPause(6000);
    await sceneAction(originalScene, secondScene.title); await playPause(9000);
    for (const tab of ['Characters', 'Storyboard', 'Script']) { await step.selectTab(tab); assert.deepEqual(await session.command('loaded-project'), unchanged); }
    await step.key('f', ['command']); const find = await ui.reveal(node => node.placeholder === 'Find in script');
    await session.command('text', { target: find.path, text: 'lantern' });
    await session.waitFor(nodes => nodes.some(node => node.text === '1 / 2')); await step.activate('Next match');
    await session.waitFor(nodes => nodes.some(node => node.text === '2 / 2')); await step.activate('Previous match');
    await session.waitFor(nodes => nodes.some(node => node.text === '1 / 2')); await step.key('Escape');
    await session.waitFor(nodes => !nodes.some(node => node.placeholder === 'Find in script'));
    assert.deepEqual(await session.command('loaded-project'), unchanged);
    // Seeking inside the six-second direction selects a concrete, timed source.
    await followPlayback(); await selectFilmPlaybackPosition(session, ui, 100);
    historyPrior = structuredClone(current); await replaceSelected(endingID, film.revisedEnding);
    const revised = structuredClone(current);
    async function historyTransition(redo, expected) {
      const operation = redo ? 'Redo' : 'Undo', before = current;
      const identity = await session.command('loaded-project');
      assert.deepEqual(identity.project, before, `${operation} starts from the exact saved film`);
      await step.workspaceHistory(redo); // One real workspace command; never retry a mutation.
      const after = await step.saved(project => project.id === before.id && project.revision > before.revision);
      assert.equal(after.revision, before.revision + 1, `${operation} creates exactly one accepted revision`);
      assert.ok(Number.isFinite(after.modifiedAt) && after.modifiedAt >= before.modifiedAt);
      assert.deepEqual(stable(after), stable(expected), `${operation} restores the entire cross-feature film`);
      const observed = await session.command('loaded-project');
      assert.deepEqual(observed.project, after, `${operation} matches the complete persisted film`);
      assert.equal(observed.dateReferenceTimeBits.createdAt, identity.dateReferenceTimeBits.createdAt);
      assert.deepEqual(observed.dateReferenceTimeBits.images, identity.dateReferenceTimeBits.images,
        `${operation} preserves every immutable project/image Date bit, not only rounded JSON dates`);
      current = after; await packages();
      assert.deepEqual(await session.command('presented-alerts'), [], `${operation} leaves no confirmation or error alert`);
    }
    await historyTransition(false, historyPrior);
    await historyTransition(true, revised);
    // Capture a single final edit as the history boundary after exercising undo.
    historyPrior = structuredClone(current); await replaceSelected(endingID, film.revisedEnding + ' Fade out.');
    assert.equal(current.revision, historyPrior.revision + 1, 'The history boundary is exactly one accepted edit, with no hidden intermediate flush');
    const witness = await session.command('loaded-project');
    await step.activate('Script history');
    const history = await session.waitFor(nodes => nodes.some(node => node.title === 'Restore revision…' && node.enabled)
      && nodes.some(node => node.text === `Revision ${historyPrior.revision}`));
    const sources = history.filter(node => node.segments?.join('|') === 'This Mac|Cloud'); assert.equal(sources.length, 1); assert.equal(sources[0].selected, 0);
    const tabs = await ui.reveal(node => node.segments?.join('|') === 'Changes|Revision preview'); await session.command('select', { target: tabs.path, index: 1 });
    const summary = '2 scenes · 5 entries · 2 characters · 2 image cues · 2 local audio clips';
    const preview = await session.waitFor(nodes => nodes.some(node => node.text === summary));
    const heading = preview.find(node => node.text === summary), prefix = heading.path.slice(0, heading.path.lastIndexOf('.')) + '.';
    const detail = preview.filter(node => node.path.startsWith(prefix));
    assert.ok(detail.some(node => node.text === film.revisedEnding && node.editable === false));
    for (const character of cast) assert.equal(detail.filter(node => node.title === character.name && node.enabled === true).length, 1,
      'The known prior revision retains each renamed/current character disclosure');
    assert.ok(!detail.some(node => node.text === film.revisedEnding + ' Fade out.'));
    await packages(); await step.activate('Close');
    await session.waitFor(nodes => !nodes.some(node => node.title === 'Restore revision…'));
    assert.deepEqual(await session.command('loaded-project'), witness, 'Read-only history preserves every field and Date bit');
  });

  await chapter('save-switch-away-reopen-and-prove-outcome', async () => {
    await sceneAction(secondScene, originalScene.title);
    await selectFilmPlaybackPosition(session, ui, current.cues.find(cue => cue.id === cueID).startMs);
    await step.workspaceCommand('s'); const expected = await session.command('loaded-project');
    assert.deepEqual((await ui.openProject(sentinel)).project, sentinel);
    assert.deepEqual(await ui.openProject(current), expected, 'Reopen retains the full authored model and immutable image/project Date bits');
    await imageEvidence();
    assert.equal(current.scenes.length, 2); assert.equal(current.entries.length, 5);
    for (const [id, text] of [[openingID, film.opening], [originalDialogueID, film.firstLine], [dialogueID, film.revisedLine + ' Ready.'],
      [endingID, film.revisedEnding + ' Fade out.'], [lastID, film.lastLine]]) assert.equal(entry(id).text, text);
    assert.deepEqual(current.characters, cast); assert.equal(cast[0].name, film.revisedCast.name);
    assert.deepEqual(entry(dialogueID).characterLinks, [confirmedLink]); assert.equal(confirmedLink.text, film.cast[0].name);
    assert.deepEqual(current.images[0].characterIds, cast.map(character => character.id).sort());
    assert.deepEqual(current.images[1].characterIds, [cast[0].id]);
    assert.equal(cast[0].portraitImageId, current.images[1].id); assert.equal(cast[1].portraitImageId, firstImageID);
    assert.equal(current.images[1].previousVersionId, firstImageID); assert.equal(current.cues.find(cue => cue.id === cueID).imageId, firstImageID);
    assert.equal(current.audioClips.find(clip => clip.id === linkedClipID).entryId, dialogueID);
    assert.equal(current.audioClips.find(clip => clip.id === sceneClipID).entryId, undefined);
    assert.equal(current.audioVolume, 0.25); assert.equal(entry(endingID).ownedDurationMs, 6000);
    assert.equal(entry(endingID).coverageDurationMs, 12000); assert.equal(current.cues.length, 2);
    for (const value of current.entries.filter(item => item.kind === 'dialogue')) spokenWords(value.words, value.text, value.ownedDurationMs);
  });
  await chapter('cold-relaunch-and-reopen-owned-film', async () => {
    const expected = await session.command('loaded-project'), oldSessionID = (await session.command('capabilities')).sessionID;
    await packages();
    session = await session.relaunch(); retainSession(session);
    step = scriptAuthoringSteps(session); ui = audioLibrarySteps(session);
    const resumed = await session.command('capabilities');
    assert.equal(session.root, root); assert.equal(resumed.runID, runID);
    assert.notEqual(resumed.sessionID, oldSessionID);
    assert.deepEqual(resumed.workspace, { persistent: true, resumed: true });
    assert.equal(resumed.cloudIsolation.network, 'disabled');
    assert.equal(resumed.cloudIsolation.credentials, 'process-memory');
    // A resumed process initially displays a NEW UNSAVED startup sample.
    // Do not invoke Save/checkpoint until the existing film is really opened.
    await packages();
    assert.deepEqual(await ui.openProject(current), expected,
      'Cold process reload retains every model field, immutable Date witness and cross-feature identity');
    await packages(); await imageEvidence();
    const { settledTrimObservation } = await import('./support/audio-attachment-steps.mjs');
    // Both recordings share Synthetic.wav, so bind every visible control to its
    // own clip card. A value or badge on the other recording cannot satisfy it.
    const audioReview = [
      { id: linkedClipID, badge: `Follows ${film.revisedCast.name}’s dialogue`, volume: 0.375, percent: '37 percent',
        fields: ['0.500', '2.000', '0.250'], attachment: `${film.revisedCast.name} · ${film.revisedLine} Ready.`, offset: 'Offset from line' },
      { id: sceneClipID, badge: 'Scene track', volume: 1, percent: '100 percent',
        fields: ['0.000', '4.000', '0.000'], attachment: 'Scene time', offset: 'Scene start' },
    ];
    for (const review of audioReview) {
      const clip = current.audioClips.find(item => item.id === review.id); assert.ok(clip);
      await ui.openLibrary();
      await ui.reveal(node => node.identifier === `audio-clip-play-${review.id}`);
      const nodes = await session.command('snapshot');
      const plays = nodes.filter(node => node.identifier === `audio-clip-play-${review.id}` && node.enabled === true);
      assert.equal(plays.length, 1);
      const cards = nodes.filter(node => node.type === 'AudioClipCardView' && plays[0].path.startsWith(node.path + '.'));
      assert.equal(cards.length, 1, 'The exact playable clip has one owning card');
      const card = nodes.filter(node => node.path.startsWith(cards[0].path + '.'));
      assert.equal(card.filter(node => node.identifier === `audio-clip-play-${review.id}` && node.enabled === true).length, 1);
      assert.equal(card.filter(node => node.identifier === `audio-clip-trim-${review.id}` && node.enabled === true).length, 1);
      assert.equal(card.filter(node => node.text === review.badge).length, 1, 'Cold reload renders the current renamed attachment');
      const volumes = card.filter(node => node.label === 'Clip volume for ' + syntheticFilename && node.slider);
      assert.equal(volumes.length, 1); assert.equal(volumes[0].slider.value, review.volume); assert.equal(volumes[0].value, review.percent);
      assert.equal(card.filter(node => node.label === 'Mute ' + syntheticFilename && node.enabled === true).length, 1,
        'The persisted unmuted clip offers Mute, not Unmute');
      await ui.openTrim(clip, review.fields);
      const editor = await session.waitFor(nodes => nodes.some(node => node.identifier === 'audio-anchor' && node.title === review.attachment && node.enabled));
      assert.equal(editor.filter(node => node.identifier === 'audio-anchor').length, 1);
      assert.equal(editor.filter(node => node.text === review.offset).length, 1);
      assert.deepEqual(await settledTrimObservation(session), expected, 'Opening saved trim fields never changes the cold-loaded model or Date bits');
      await packages(); assert.deepEqual(await session.command('presented-alerts'), []);
      await ui.finishTrim(false); await packages();
      assert.deepEqual(await session.command('presented-alerts'), []);
      await ui.closeLibrary();
      assert.deepEqual(await session.command('loaded-project'), expected, 'Cancel and close preserve the full film, revision and Date bits');
    }
    const reopenedCatalog = characterCatalogSteps(session);
    await reopenedCatalog.openCatalog({ persist: false }); await reopenedCatalog.text(reopenedCatalog.searchField, film.revisedCast.name);
    await session.waitFor(nodes => {
      const ribbons = nodes.filter(node => node.identifier?.startsWith('character-ribbon-'));
      return ribbons.length === 1 && ribbons[0].identifier === `character-ribbon-${cast[0].id}` && ribbons[0].label === film.revisedCast.name;
    });
    assert.deepEqual(await session.command('loaded-project'), expected); await packages();
    await ui.activate(node => node.identifier === `character-ribbon-${cast[0].id}`);
    await reopenedCatalog.activate('Edit'); await reopenedCatalog.rememberOpeningPalette();
    // Inspect the cold-reloaded form itself, including decomposed accents,
    // trailing spaces and line breaks. No field is changed or saved here.
    await reopenedCatalog.inspectEditor(film.revisedCast);
    // The loaded-project observer deliberately excludes this modal. Use the
    // persisted packages now and compare the full native witness after Cancel.
    await packages(); assert.deepEqual(await session.command('presented-alerts'), []);
    await reopenedCatalog.cancelCleanEditor();
    assert.deepEqual(await session.command('loaded-project'), expected,
      'Inspecting and cancelling the reopened character preserves every film field, revision and native Date bit');
    await packages(); assert.deepEqual(await session.command('presented-alerts'), []);
    await reopenedCatalog.text(reopenedCatalog.searchField, ''); await step.selectTab('Script');
    assert.deepEqual(await session.command('loaded-project'), expected);
  });
  assert.deepEqual(completed, shortFilmContract.chapters);
  console.log('PASS FILM-J01: one continuous film, eleven chapters, same owned root/project across two processes, exact sentinel and cold reopened outcome. No 100% coverage claim.');
}

// Standard swatches keep their UI order after the optional retained opening colour.
// Labels alone are ambiguous when literal "blue" and standard hex blue coexist.
async function selectStandardSwatch(session, catalog, name) {
  const names = ['Orange', 'Yellow', 'Green', 'Teal', 'Blue', 'Purple', 'Pink', 'Slate'];
  const labels = names.map(value => `${value} character colour`), index = names.indexOf(name);
  assert.ok(index >= 0, 'The independent profile names one standard swatch');
  function inspect(nodes) {
    const palette = nodes.filter(node => / character colour$/.test(node.label ?? ''));
    assert.ok(palette.length === 8 || palette.length === 9, 'Only the standard palette and optional retained opening colour');
    const offset = palette.length - 8;
    assert.deepEqual(palette.slice(offset).map(node => node.label), labels);
    if (offset) assert.equal(palette[0].label, 'Blue character colour', 'New profiles retain their opening blue swatch');
    assert.ok(palette.every(node => node.enabled === true));
    const parent = palette[0].path.slice(0, palette[0].path.lastIndexOf('.'));
    assert.ok(palette.every(node => node.path.slice(0, node.path.lastIndexOf('.')) === parent));
    assert.equal(new Set(palette.map(node => node.path)).size, palette.length);
    return { palette, selected: palette[offset + index] };
  }
  const before = inspect(await session.command('snapshot')), selected = before.selected;
  await catalog.locate(node => node.path === selected.path && node.label === selected.label
    && node.enabled === true, `standard ${name} character colour`);
  const after = inspect(await session.command('snapshot'));
  assert.deepEqual(after.palette.map(node => [node.path, node.label]), before.palette.map(node => [node.path, node.label]));
  assert.equal(after.selected.hittable, true);
  assert.equal((await session.command('activate', { target: after.selected.path })).dispatched, true);
}

async function selectFilmPlaybackPosition(session, ui, value) {
  const control = await ui.reveal(node => node.label === 'Playback position' && !!node.slider);
  const range = control.slider.maximum - control.slider.minimum;
  const tolerance = Math.max(0.001, range * 2 ** -21); // Milliseconds, bounded Float slider scaling error.
  assert.ok(Number.isFinite(value) && Number.isFinite(tolerance) && tolerance <= 2);
  assert.ok(value >= control.slider.minimum && value <= control.slider.maximum);
  await session.command('slider', { target: control.path, value });
  try {
    await session.waitFor(nodes => nodes.some(node => node.identifier === control.identifier
      && node.label === 'Playback position' && node.enabled && node.hittable
      && Math.abs(node.slider?.value - value) <= tolerance));
  } catch (error) {
    const nodes = await session.command('snapshot');
    const observed = nodes.filter(node => node.label === 'Playback position').slice(0, 4)
      .map(node => ({ identifier: node.identifier, enabled: node.enabled, hittable: node.hittable, slider: node.slider }));
    throw new Error(`Film playback selection failed: ${JSON.stringify({ requested: value, tolerance, observed })}`, { cause: error });
  }
}
