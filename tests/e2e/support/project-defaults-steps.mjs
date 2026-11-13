import assert from 'node:assert/strict';

export function assertBlankProject(project, earliest, latest) {
  // UUIDs and clock values are independently constrained before substituting
  // their identities into a complete, independently authored stable model.
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  assert.equal(project.scenes.length, 1);
  assert.equal(project.entries.length, 2);
  assert.equal(project.cues.length, 1);
  const ids = [project.id, project.scenes[0].id, ...project.entries.map(e => e.id), project.cues[0].id,
    ...project.entries[1].words.map(w => w.id)];
  for (const id of ids) assert.match(id, uuid);
  assert.equal(new Set(ids).size, 8, 'Project, scene, entries, cue and three words have distinct UUIDs');
  assert.equal(typeof project.createdAt, 'number');
  assert.ok(project.createdAt >= earliest - 1000 && project.createdAt <= latest + 1000, 'Creation clock is bounded by the actual New project action');
  assert.equal(project.modifiedAt, project.createdAt);
  const sceneId = project.scenes[0].id;
  assert.deepEqual(project, {
    schemaVersion: 1, id: project.id, title: 'Untitled', createdAt: project.createdAt,
    modifiedAt: project.createdAt, revision: 0,
    scenes: [{ id: sceneId, title: 'INT. LOCATION — DAY', order: 0 }],
    entries: [
      { id: project.entries[0].id, sceneId, order: 0, kind: 'direction', text: 'Describe the opening moment.',
        ownedDurationMs: 0, coverageDurationMs: 3000, color: 'purple', words: [] },
      { id: project.entries[1].id, sceneId, order: 1, kind: 'dialogue', text: 'Your first line.',
        ownedDurationMs: 3000, coverageDurationMs: 0, color: 'purple', words: [
          { id: project.entries[1].words[0].id, text: 'Your', startMs: 0, endMs: 857 },
          { id: project.entries[1].words[1].id, text: 'first', startMs: 857, endMs: 1928 },
          { id: project.entries[1].words[2].id, text: 'line.', startMs: 1928, endMs: 3000 }
        ] }
    ],
    characters: [], images: [], cues: [{ id: project.cues[0].id, sceneId, label: '01A', startMs: 0, endMs: 3000, prompt: '' }],
    audioAssets: [], audioClips: [], audioVolume: 1
  }, 'Every encoded blank-project field has its independent expected default');
}

export async function reopenProject(session, project) {
  await session.command('activate', { target: 'workspace-project' });
  const nodes = await session.waitFor(nodes => nodes.some(n => n.placeholder === 'Find a project' && n.hittable));
  await session.command('text', { target: nodes.find(n => n.placeholder === 'Find a project' && n.hittable).path, text: project.title });
  await session.waitFor(nodes => nodes.some(n => n.text === `${project.title} · 1 scene`));
  const ready = await session.waitFor(nodes => nodes.some(n => n.title === 'Open project' && n.hittable && n.enabled));
  await session.command('activate', { target: ready.find(n => n.title === 'Open project' && n.hittable && n.enabled).path });
  await session.waitFor(nodes => nodes.some(n => n.identifier === 'workspace-project' && n.title === project.title && n.hittable));
  assert.deepEqual((await session.command('loaded-project')).project, project, 'Real browser reopen preserves every project field and identity');
  assert.deepEqual(await session.command('presented-alerts'), []);
}
