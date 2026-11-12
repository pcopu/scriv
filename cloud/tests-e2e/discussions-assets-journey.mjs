// Real HTTP service-process integration; not Catalyst/native application E2E.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, rm, readFile, readdir, copyFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';

const here = await realpath(dirname(fileURLToPath(import.meta.url)));
// --cloud supports an outside-repository candidate without changing its sources.
const cloud = await realpath(process.argv[2] === '--owned-child' ? process.argv[4] :
  process.argv[2] === '--cloud' ? process.argv[3] : join(here, '..'));
const self = await realpath(fileURLToPath(import.meta.url));
if (process.argv[2] !== '--owned-child') {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'scriv-discussions-assets-')));
  let child;
  let timer;
  const killOwned = signal => {
    if (child?.pid) {
      try { process.kill(-child.pid, signal); } catch (error) { if (error.code !== 'ESRCH') throw error; }
    }
  };
  const interrupt = () => killOwned('SIGTERM');
  try {
    for (const name of ['home', 'tmp', 'state']) await mkdir(join(root, name), { mode: 0o700 });
    // Resolve installed dependencies from an owned runner, never edit the repository.
    await copyFile(self, join(root, 'runner.mjs'));
    await symlink(await realpath(join(cloud, 'node_modules')), join(root, 'node_modules'), 'dir');
    child = spawn(process.execPath, [join(root, 'runner.mjs'), '--owned-child', root, cloud], {
      cwd: root, detached: true, stdio: 'inherit',
      // Deliberately no inherited credentials, proxy settings, config, or NODE_OPTIONS.
      env: { PATH: dirname(process.execPath), HOME: join(root, 'home'), TMPDIR: join(root, 'tmp'),
        XDG_CONFIG_HOME: join(root, 'home'), XDG_CACHE_HOME: join(root, 'home'),
        WRANGLER_SEND_METRICS: 'false', CI: '1' },
    });
    process.on('SIGINT', interrupt); process.on('SIGTERM', interrupt);
    timer = setTimeout(() => killOwned('SIGKILL'), 90_000);
    const result = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', (code, signal) => resolve({ code, signal }));
    });
    assert.equal(result.code, 0, `Owned service journey failed: exit=${result.code}, signal=${result.signal}`);
  } finally {
    clearTimeout(timer);
    process.off('SIGINT', interrupt); process.off('SIGTERM', interrupt);
    killOwned('SIGKILL');
    await rm(root, { recursive: true, force: true });
    console.log('Owned service process group and temporary state cleaned.');
  }
} else {
  const root = await realpath(process.argv[3]);
  assert.equal(await realpath(process.cwd()), root);
  assert.equal(process.env.HOME, join(root, 'home'));
  const { build } = await import('esbuild');
  const { Miniflare, Log, LogLevel, convertV4MiniflareOptions } = await import('miniflare');
  const { unstable_splitSqlQuery } = await import('wrangler');
  const bundle = join(root, 'worker.mjs');
  await build({ entryPoints: [join(cloud, 'src/index.ts')], outfile: bundle,
    bundle: true, format: 'esm', platform: 'neutral', target: 'es2022',
    external: ['cloudflare:*'], logLevel: 'silent' });
  let outboundAttempts = 0;
  const denyOutbound = () => { outboundAttempts++; throw new Error('Unexpected outbound request denied'); };
  // The installed Miniflare 5 adapter translates this explicit, local-only config.
  const common = { unsafeInspectorProxy: false, compatibilityDate: '2026-10-29', modules: true, outboundService: denyOutbound };
  const config = convertV4MiniflareOptions({
    host: '127.0.0.1', port: 0, cf: false, telemetry: { enabled: false },
    unsafeLocalExplorer: false, unsafeObservability: false,
    unsafeEnableSharedStorage: false, logRequests: false, log: new Log(LogLevel.ERROR),
    resourcePersistencePath: join(root, 'state'), resourceTmpPath: join(root, 'tmp'),
    workers: [{ ...common, name: 'scriv', scriptPath: bundle,
      bindings: { PUBLIC_URL: 'http://127.0.0.1', ENVIRONMENT: 'test', ASSET_MAX_BYTES: '12' },
      d1Databases: { DB: 'journey-db' }, r2Buckets: ['MEDIA'],
      durableObjects: { PROJECTS: { className: 'ProjectRoom', useSQLite: true }, BILLING: { className: 'BillingCoordinator', useSQLite: true } },
    }],
  });
  const mf = new Miniflare(config);
  let requests = 0;
  try {
    const db = await mf.getD1Database('DB', 'scriv');
    const migrations = (await readdir(join(cloud, 'migrations'))).filter(name => /^\d+_.+\.sql$/.test(name)).sort();
    assert.deepEqual(migrations, ['0001_identity_teams.sql', '0002_generation_jobs.sql', '0003_email_auth.sql']);
    for (const name of migrations) await db.batch(unstable_splitSqlQuery(await readFile(join(cloud, 'migrations', name), 'utf8')).map(sql => db.prepare(sql)));
    // Fixture provisioning only, before HTTP: ephemeral identities, hashed sessions
    // and a synthetic paid team. This does not test provider login or billing.
    const now = Date.now(), teamId = randomUUID(), projectId = randomUUID(), itemId = randomUUID();
    const actors = {};
    for (const role of ['owner', 'member', 'viewer', 'outsider']) {
      const actor = actors[role] = { id: randomUUID(), sessionId: randomUUID(), token: randomBytes(32).toString('base64url') };
      await db.prepare('INSERT INTO users(id,github_id,name,created_at) VALUES(?,?,?,?)').bind(actor.id, `email:${actor.id}`, `Synthetic ${role}`, now).run();
      await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)').bind(createHash('sha256').update(actor.token).digest('hex'), actor.sessionId, actor.id, 'Synthetic CLI device', now, now + 3600000).run();
    }
    await db.prepare('INSERT INTO teams(id,name,owner_id,created_at,subscription_status,paid_until) VALUES(?,?,?,?,?,?)').bind(teamId, 'Synthetic collaboration team', actors.owner.id, now, 'active', now + 3600000).run();
    for (const role of ['owner', 'member', 'viewer']) await db.prepare('INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES(?,?,?,?)').bind(teamId, actors[role].id, role, now).run();
    const bucket = await mf.getR2Bucket('MEDIA', 'scriv');
    assert.deepEqual((await bucket.list()).objects, []);
    async function request(path, { role = 'owner', method = 'GET', body, status = 200, code } = {}) {
      const base = await mf.ready;
      assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:'); assert(Number(base.port) > 0);
      const url = new URL(path, base); assert.equal(url.origin, base.origin);
      const encoded = body === undefined ? undefined : JSON.stringify(body);
      assert(requests++ < 80); assert(Buffer.byteLength(encoded ?? '') <= 16384);
      const response = await fetch(url, { method, headers: { authorization: `Bearer ${actors[role].token}`, ...(encoded ? { 'content-type': 'application/json' } : {}) }, body: encoded, redirect: 'error', signal: AbortSignal.timeout(5000) });
      // Never include response bodies or headers in errors: leases are secrets.
      assert.equal(response.status, status, `${method} ${path} status`);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      const reader = response.body?.getReader(); const parts = []; let size = 0;
      if (reader) while (true) { const { done, value } = await reader.read(); if (done) break; size += value.length; assert(size <= 65536, 'Response bound'); parts.push(value); }
      const data = JSON.parse(Buffer.concat(parts).toString('utf8'));
      if (code) assert.equal(data.error?.code, code, `${method} ${path} error code`);
      return data;
    }
    const route = suffix => `/v1/projects/${projectId}/${suffix}`;
    const post = (body, extra = {}) => ({ method: 'POST', body, ...extra });
    const created = await request('/v1/projects', post({ id: projectId, title: 'Synthetic discussion', teamId }, { role: 'member', status: 201 }));
    assert.equal(created.project.id, projectId);
    await request(route('threads'), { role: 'outsider', status: 404, code: 'not_found' });
    assert.deepEqual((await request(route('threads'))).threads, []);
    const thread = (await request(route('threads'), post({}, { role: 'member', status: 201 }))).thread;
    assert.equal(thread.itemId, null); assert.equal(thread.resolved, false);
    assert.deepEqual((await request(route('threads'), post({}, { role: 'viewer' }))).thread, thread);
    assert.equal((await request(route('threads?scope=all'), { role: 'viewer' })).threads[0].id, thread.id);
    await request(route(`threads?scope=all&itemId=${itemId}`), { status: 400, code: 'invalid_scope' });
    await request(route('threads'), post({ itemId }, { status: 404, code: 'not_found' }));
    const messages = route(`threads/${thread.id}/messages`);
    const first = { id: randomUUID(), body: '  A synthetic comment  ', mentionedUserIds: [actors.member.id] };
    const sent = await request(messages, post(first, { role: 'member', status: 201 }));
    assert.equal(sent.message.body, 'A synthetic comment'); assert.equal(sent.message.userId, actors.member.id);
    assert.deepEqual(sent.message.mentionedUserIds, [actors.member.id]);
    assert.deepEqual(await request(messages, post(first, { role: 'member' })), sent);
    await request(messages, post({ ...first, body: 'changed' }, { role: 'member', status: 409, code: 'message_reused' }));
    await request(messages, post({ id: randomUUID(), body: '  ' }, { status: 400, code: 'empty_message' }));
    await request(messages, post({ id: randomUUID(), body: 'Invalid reply', replyToId: randomUUID() }, { status: 400, code: 'invalid_reply' }));
    await request(messages, post({ id: randomUUID(), body: 'Invalid mention', mentionedUserIds: [actors.outsider.id] }, { status: 400, code: 'invalid_mentions' }));
    await request(messages, post({ id: randomUUID(), body: 'Duplicate mention', mentionedUserIds: [actors.member.id, actors.member.id] }, { status: 400, code: 'invalid_mentions' }));
    const reply = await request(messages, post({ id: randomUUID(), body: 'Synthetic reply', replyToId: first.id }, { role: 'viewer', status: 201 }));
    assert.equal(reply.message.replyToId, first.id);
    const listing = await request(messages, { role: 'viewer' });
    assert.deepEqual(listing.messages.map(m => m.id), [first.id, reply.message.id]);
    assert(reply.message.at > sent.message.at);
    assert.deepEqual((await request(`${messages}?after=${sent.message.at}&afterId=${first.id}`)).messages.map(m => m.id), [reply.message.id]);
    const resolved = await request(route(`threads/${thread.id}`), { method: 'PATCH', body: { resolved: true } });
    assert.equal(resolved.thread.resolved, true);
    assert.deepEqual(await request(route(`threads/${thread.id}`), { method: 'PATCH', body: { resolved: true } }), resolved);
    const reopened = await request(route(`threads/${thread.id}`), { method: 'PATCH', body: { resolved: false } });
    assert.equal(reopened.thread.resolved, false);
    const history = await request(route('history?after=0'));
    assert.deepEqual(history.events.map(e => e.kind), ['discussion.thread-created', 'discussion.message-created', 'discussion.message-created', 'discussion.thread-updated', 'discussion.thread-updated']);
    assert.equal((await request(route('snapshot'))).threads[0].id, thread.id);
    // Real content-addressed R2 route with inert synthetic PNG-signature bytes.
    const content = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4]);
    const hash = createHash('sha256').update(content).digest('hex');
    const asset = route(`assets/${hash}`);
    async function media(path, { role = 'owner', method = 'GET', data, type, status = 200, code } = {}) {
      const base = await mf.ready; assert.equal(base.hostname, '127.0.0.1');
      const url = new URL(path, base); assert.equal(url.origin, base.origin);
      assert(requests++ < 80); assert((data?.length ?? 0) <= 16384);
      const response = await fetch(url, { method, headers: { authorization: `Bearer ${actors[role].token}`, ...(type ? { 'content-type': type } : {}) }, body: data, redirect: 'error', signal: AbortSignal.timeout(5000) });
      assert.equal(response.status, status, `${method} asset status`);
      assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      const reader = response.body?.getReader(); const parts = []; let size = 0;
      if (reader) while (true) { const { done, value } = await reader.read(); if (done) break; size += value.length; assert(size <= 65536, 'Response bound'); parts.push(value); }
      const bytes = Buffer.concat(parts);
      if (code) assert.equal(JSON.parse(bytes.toString()).error?.code, code);
      return { response, bytes };
    }
    await media(asset, { role: 'viewer', status: 404, code: 'asset_unavailable' });
    await media(asset, { role: 'viewer', method: 'PUT', data: content, type: 'image/png', status: 402, code: 'team_subscription_required' });
    await media(asset, { role: 'member', method: 'PUT', data: content, type: 'image/jpeg', status: 415, code: 'invalid_media' });
    await media(route(`assets/${'0'.repeat(64)}`), { role: 'member', method: 'PUT', data: content, type: 'image/png', status: 422, code: 'hash_mismatch' });
    const uploaded = await media(asset, { role: 'member', method: 'PUT', data: content, type: 'image/png', status: 201 });
    assert.deepEqual(JSON.parse(uploaded.bytes.toString()), { sha256: hash, bytes: content.length, hosted: true });
    assert.deepEqual(JSON.parse((await media(asset, { role: 'member', method: 'PUT', data: content, type: 'image/png' })).bytes.toString()), { sha256: hash, bytes: content.length, hosted: true });
    assert.equal((await bucket.list()).objects.length, 1);
    const downloaded = await media(asset, { role: 'viewer' });
    assert.deepEqual(downloaded.bytes, content); assert.equal(downloaded.response.headers.get('content-type'), 'image/png');
    assert.equal(downloaded.response.headers.get('x-scriv-sha256'), hash);
    assert.equal(downloaded.response.headers.get('etag'), `"${hash}"`);
    assert.equal(downloaded.response.headers.get('cache-control'), 'private, no-store');
    const head = await media(asset, { method: 'HEAD', role: 'viewer' });
    assert.equal(head.bytes.length, 0); assert.equal(head.response.headers.get('content-length'), String(content.length));
    await media(asset, { role: 'outsider', status: 404, code: 'not_found' });
    await media(asset, { role: 'member', method: 'DELETE', status: 403, code: 'not_allowed' });
    assert.deepEqual((await media(asset, { role: 'viewer' })).bytes, content);
    await media(asset, { method: 'DELETE' });
    await media(asset, { method: 'DELETE' });
    await media(asset, { status: 404, code: 'asset_unavailable' });
    assert.deepEqual((await bucket.list()).objects, []);
    assert.equal((await db.prepare('SELECT COUNT(*) n FROM assets').first()).n, 0);
    // Loss of subscription leaves grace reads and exact retries intact, but rejects new writes.
    await db.prepare("UPDATE teams SET subscription_status='canceled', paid_until=? WHERE id=?").bind(Date.now() - 1000, teamId).run();
    assert.deepEqual(await request(messages, post(first, { role: 'member' })), sent);
    await request(messages, post({ id: randomUUID(), body: 'New after lapse' }, { role: 'member', status: 403, code: 'read_only' }));
    assert.equal((await request(messages, { role: 'member' })).messages.length, 2);
    // A second media chapter uses the same isolated Worker and original actors.
    // Restore only the synthetic billing fixture; no provider or production account.
    await db.prepare("UPDATE teams SET subscription_status='active', paid_until=? WHERE id=?").bind(Date.now() + 3600000, teamId).run();
    const mediaCases = [];
    async function boundary(label, data, { method = 'PUT', type = 'image/png', hash, assetId, status, code, message, streaming = false } = {}) {
      assert.ok(Buffer.isBuffer(data)); assert.ok(data.length <= 32);
      hash ??= createHash('sha256').update(data).digest('hex');
      const base = await mf.ready; assert.equal(base.hostname, '127.0.0.1'); assert.equal(base.protocol, 'http:');
      const url = new URL(route(`assets/${hash}`), base); assert.equal(url.origin, base.origin);
      const headers = { authorization: `Bearer ${actors.member.token}`, 'content-type': type };
      if (assetId !== undefined) headers['x-scriv-asset-id'] = assetId;
      // Streaming sends no supplied Content-Length, exercising the same public byte bound.
      const body = streaming ? new ReadableStream({ start(controller) {
        controller.enqueue(data.subarray(0, 8)); controller.enqueue(data.subarray(8)); controller.close();
      } }) : data;
      assert(requests++ < 80);
      const response = await fetch(url, { method, headers, body, ...(streaming ? { duplex: 'half' } : {}),
        redirect: 'error', signal: AbortSignal.timeout(5000) });
      assert.equal(response.status, status, label);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
      assert.equal(response.headers.get('content-type'), 'application/json; charset=utf-8');
      const reader = response.body.getReader(), parts = []; let size = 0;
      while (true) { const { done, value } = await reader.read(); if (done) break; size += value.length; assert(size <= 65536); parts.push(value); }
      const result = JSON.parse(Buffer.concat(parts).toString('utf8'));
      if (code) assert.deepEqual(result, { error: { code, message } }, label);
      else assert.deepEqual(result, { sha256: hash, bytes: data.length, hosted: true }, label);
      mediaCases.push(label); return hash;
    }
    // MIME signatures are inert fixtures, not claims that these are decoded images.
    const formats = [
      { type: 'image/jpeg', bytes: Buffer.from([255, 216, 255]), assetId: 'synthetic.jpeg:1' },
      { type: 'image/webp', bytes: Buffer.from([82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80]), assetId: 'synthetic.webp:1' },
    ];
    for (const format of formats) {
      format.hash = await boundary(`upload-${format.type}`, format.bytes, { type: format.type + '; charset=binary', assetId: format.assetId, status: 201 });
      await boundary(`retry-${format.type}`, format.bytes, { type: format.type, status: 200 });
      const downloaded = await media(route(`assets/${format.hash}`), { role: 'viewer' });
      assert.deepEqual(downloaded.bytes, format.bytes); assert.equal(downloaded.response.headers.get('content-type'), format.type);
      assert.equal(downloaded.response.headers.get('content-length'), String(format.bytes.length));
      assert.equal(downloaded.response.headers.get('etag'), `"${format.hash}"`);
      assert.equal(downloaded.response.headers.get('x-scriv-sha256'), format.hash);
      assert.equal(downloaded.response.headers.get('cache-control'), 'private, no-store');
      const head = await media(route(`assets/${format.hash}`), { method: 'HEAD', role: 'viewer' });
      assert.equal(head.bytes.length, 0); assert.equal(head.response.headers.get('content-length'), String(format.bytes.length));
      assert.equal(head.response.headers.get('content-type'), format.type);
      assert.equal(head.response.headers.get('etag'), `"${format.hash}"`);
      assert.equal(head.response.headers.get('x-scriv-sha256'), format.hash);
      assert.equal(head.response.headers.get('cache-control'), 'private, no-store');
    }
    // Read-only synthetic storage evidence catches reservations and orphan objects
    // that an unchanged public missing-asset response alone would overlook.
    async function mediaState() {
      const rows = (await db.prepare('SELECT * FROM assets ORDER BY sha256').all()).results;
      const objects = [];
      for (const item of (await bucket.list()).objects.sort((a, b) => a.key.localeCompare(b.key))) {
        const object = await bucket.get(item.key); assert.ok(object);
        objects.push({ key: item.key, bytes: Buffer.from(await object.arrayBuffer()).toString('hex'),
          contentType: object.httpMetadata?.contentType, metadata: object.customMetadata });
      }
      return { rows, objects };
    }
    const baselineMedia = await mediaState();
    assert.equal(baselineMedia.rows.length, 2); assert.equal(baselineMedia.objects.length, 2);
    for (const format of formats) {
      const row = baselineMedia.rows.find(row => row.sha256 === format.hash);
      assert.ok(row); assert.equal(row.state, 'ready'); assert.equal(row.asset_id, format.assetId);
      assert.equal(row.content_type, format.type); assert.equal(row.bytes, format.bytes.length);
      assert.equal(row.project_id, projectId); assert.equal(row.team_id, teamId); assert.equal(row.uploaded_by, actors.member.id);
      const object = baselineMedia.objects.find(object => object.key === row.object_key);
      assert.ok(object); assert.equal(object.bytes, format.bytes.toString('hex')); assert.equal(object.contentType, format.type);
      assert.deepEqual(object.metadata, { sha256: format.hash, projectId, teamId });
    }
    const refusals = [
      ['empty', Buffer.alloc(0), { status: 400, code: 'empty_media', message: 'The image is empty.' }],
      ['short-signature', Buffer.from([137, 80, 78]), { status: 415, code: 'invalid_media', message: 'The bytes must match a PNG, JPEG or WebP Content-Type.' }],
      ['wrong-mime', formats[0].bytes, { type: 'image/webp', status: 415, code: 'invalid_media', message: 'The bytes must match a PNG, JPEG or WebP Content-Type.' }],
      ['wrong-hash', formats[0].bytes, { type: 'image/jpeg', hash: '0'.repeat(64), status: 422, code: 'hash_mismatch', message: 'Image SHA-256 does not match its content-addressed URL.' }],
      ['invalid-asset-id', content, { assetId: 'invalid id', status: 400, code: 'invalid_id', message: 'assetId contains unsupported characters.' }],
      ['known-length-limit', Buffer.concat([content, Buffer.from([5])]), { status: 413, code: 'body_too_large', message: 'Request exceeds the size limit.' }],
      ['streamed-length-limit', Buffer.concat([content, Buffer.from([5])]), { streaming: true, status: 413, code: 'body_too_large', message: 'Request exceeds the size limit.' }],
      ['unsupported-method', content, { method: 'POST', status: 405, code: 'method_not_allowed', message: 'Use GET, PUT or DELETE for image media.' }],
    ];
    for (const [label, data, options] of refusals) {
      await boundary(label, data, options);
      assert.deepEqual(await mediaState(), baselineMedia, `${label}: complete media rows, keys and bytes unchanged`);
    }
    for (const format of formats) assert.deepEqual((await media(route(`assets/${format.hash}`), { role: 'viewer' })).bytes, format.bytes);
    await media(route(`assets/${formats[0].hash}`), { method: 'DELETE' });
    await media(route(`assets/${formats[0].hash}`), { status: 404, code: 'asset_unavailable' });
    assert.deepEqual((await media(route(`assets/${formats[1].hash}`), { role: 'viewer' })).bytes, formats[1].bytes);
    const survivor = await mediaState();
    assert.deepEqual(survivor.rows, baselineMedia.rows.filter(row => row.sha256 === formats[1].hash));
    assert.deepEqual(survivor.objects, baselineMedia.objects.filter(object => object.metadata.sha256 === formats[1].hash));
    await media(route(`assets/${formats[1].hash}`), { method: 'DELETE' });
    await media(route(`assets/${formats[1].hash}`), { method: 'DELETE' });
    assert.deepEqual(await mediaState(), { rows: [], objects: [] });
    assert.equal(mediaCases.length, 12, 'Two uploads, two retries and eight exact boundary refusals');
    assert.equal(outboundAttempts, 0);
    // The original 63 HTTP checks remain above. This chapter uses a synthetic
    // 12-byte team quota and controlled incomplete-body permission transitions.
    const reservationStart=requests; assert.equal(reservationStart,63);
    const originalTeam=await db.prepare('SELECT * FROM teams WHERE id=?').bind(teamId).first(); assert.equal(originalTeam.storage_used,0);
    const originalMembers=(await db.prepare('SELECT * FROM team_members ORDER BY user_id').all()).results;
    await db.prepare('UPDATE teams SET storage_limit=12 WHERE id=?').bind(teamId).run();
    const quotaState=async()=>({...await mediaState(),teams:(await db.prepare('SELECT * FROM teams ORDER BY id').all()).results});
    const emptyQuota=await quotaState();
    async function reservationHTTP(path,{token=actors.owner.token,method='GET',data,json:jsonBody,type,status=200,expected}={}) {
      const base=await mf.ready,url=new URL(path,base);assert.equal(base.hostname,'127.0.0.1');assert.equal(base.protocol,'http:');assert.equal(url.origin,base.origin);
      const body=jsonBody===undefined?data:Buffer.from(JSON.stringify(jsonBody));assert((body?.length??0)<=4096);assert(requests++<110);
      const response=await fetch(url,{method,headers:{authorization:`Bearer ${token}`,...(body?{'content-type':type??'application/json'}:{})},body,redirect:'error',signal:AbortSignal.timeout(5000)});
      assert.equal(response.status,status);assert.equal(response.headers.get('cache-control'),'no-store');assert.equal(response.headers.get('x-content-type-options'),'nosniff');
      assert.equal(response.headers.get('content-type'),'application/json; charset=utf-8');
      const parts=[];let size=0;const reader=response.body.getReader();while(true){const{done,value}=await reader.read();if(done)break;size+=value.length;assert(size<=16384);parts.push(value);}
      const result=JSON.parse(Buffer.concat(parts).toString('utf8'));if(expected!==undefined)assert.deepEqual(result,expected);return result;
    }
    const pngResult={sha256:hash,bytes:content.length,hosted:true};
    const upload=(token=actors.member.token)=>({method:'PUT',token,data:content,type:'image/png',status:201,expected:pngResult});
    async function readyReplica(expectedHash,bytes,type,userId) {
      const state=await quotaState();assert.equal(state.rows.length,1);assert.equal(state.objects.length,1);
      const row=state.rows[0],object=state.objects[0];
      assert.equal(row.project_id,projectId);assert.equal(row.team_id,teamId);assert.equal(row.sha256,expectedHash);assert.equal(row.uploaded_by,userId);
      assert.equal(row.state,'ready');assert.equal(row.bytes,bytes.length);assert.equal(row.content_type,type);assert.equal(row.asset_id,null);
      assert.equal(object.key,row.object_key);assert.equal(object.bytes,bytes.toString('hex'));assert.equal(object.contentType,type);assert.deepEqual(object.metadata,{sha256:expectedHash,projectId,teamId});
      assert.equal(state.teams.find(t=>t.id===teamId).storage_used,bytes.length);return state;
    }
    await reservationHTTP(asset,upload());
    const fullQuota=await readyReplica(hash,content,'image/png',actors.member.id);
    assert.equal(fullQuota.teams[0].storage_limit,12);assert.equal(fullQuota.teams[0].storage_used,12);
    await reservationHTTP(asset,{...upload(),status:200});assert.deepEqual(await quotaState(),fullQuota);
    let publicQuota=await reservationHTTP(`/v1/teams/${teamId}`);assert.equal(publicQuota.team.storageUsed,12);
    const jpeg=formats[0],jpegPath=route(`assets/${jpeg.hash}`);
    await reservationHTTP(jpegPath,{method:'PUT',token:actors.member.token,data:jpeg.bytes,type:jpeg.type,status:413,
      expected:{error:{code:'storage_quota',message:'This team has reached its hosted image storage quota. Remove hosted replicas or raise the quota.'}}});
    assert.deepEqual(await quotaState(),fullQuota);
    await reservationHTTP(asset,{method:'DELETE',expected:{ok:true}});assert.deepEqual(await quotaState(),emptyQuota);
    await reservationHTTP(jpegPath,{method:'PUT',token:actors.member.token,data:jpeg.bytes,type:jpeg.type,status:201,expected:{sha256:jpeg.hash,bytes:3,hosted:true}});
    await readyReplica(jpeg.hash,jpeg.bytes,jpeg.type,actors.member.id);
    await reservationHTTP(jpegPath,{method:'DELETE',expected:{ok:true}});assert.deepEqual(await quotaState(),emptyQuota);
    await reservationHTTP(jpegPath,{method:'DELETE',expected:{ok:true}});assert.deepEqual(await quotaState(),emptyQuota);
    publicQuota=await reservationHTTP(`/v1/teams/${teamId}`);assert.equal(publicQuota.team.storageUsed,0);
    const {request:heldRequest}=await import('node:http');const reservationCases=[];const addedUsers=[];
    async function interruptedUpload(kind) {
      const createdAt=Date.now(),userId=randomUUID();addedUsers.push(userId);
      await db.prepare('INSERT INTO users(id,github_id,name,created_at) VALUES(?,?,?,?)').bind(userId,`email:${userId}`,`Synthetic ${kind} uploader`,createdAt).run();
      await db.prepare("INSERT INTO team_members(team_id,user_id,role,joined_at) VALUES(?,?,'member',?)").bind(teamId,userId,createdAt).run();
      async function session(name) {
        const value={id:randomUUID(),token:randomBytes(32).toString('base64url')};
        await db.prepare('INSERT INTO sessions(token_hash,id,user_id,device_name,created_at,expires_at) VALUES(?,?,?,?,?,?)').bind(createHash('sha256').update(value.token).digest('hex'),value.id,userId,name,createdAt,createdAt+3600000).run();return value;
      }
      const attempt=await session('Synthetic incomplete upload'),retained=kind==='logout'?await session('Synthetic retained upload'):attempt;
      const prefix=`upload:${userId}:`,requestPrefix=`request:${attempt.id}:`;
      const counters=async key=>(await db.prepare('SELECT * FROM security_limits WHERE substr(key,1,?)=? ORDER BY key').bind(key.length,key).all()).results;
      assert.deepEqual(await counters(prefix),[]);assert.deepEqual(await counters(requestPrefix),[]);
      const before=await quotaState();assert.deepEqual(before,emptyQuota);
      const base=await mf.ready,url=new URL(asset,base);assert.equal(url.origin,base.origin);assert.equal(base.hostname,'127.0.0.1');assert.equal(base.protocol,'http:');
      let outgoing,responseStarted=false,released=false;assert(requests++<110);
      const completion=new Promise((resolve,reject)=>{
        outgoing=heldRequest(url,{method:'PUT',agent:false,signal:AbortSignal.timeout(10000),headers:{authorization:`Bearer ${attempt.token}`,'content-type':'image/png','content-length':String(content.length)}},incoming=>{
          responseStarted=true;const chunks=[];let size=0;incoming.on('error',reject);incoming.on('data',chunk=>{size+=chunk.length;if(size>16384)incoming.destroy(new Error('Bounded held-upload response'));else chunks.push(chunk);});
          incoming.on('end',()=>{try{resolve({status:incoming.statusCode,headers:incoming.headers,data:JSON.parse(Buffer.concat(chunks).toString('utf8'))});}catch(error){reject(error);}});
        });outgoing.on('error',reject);outgoing.flushHeaders();outgoing.write(content.subarray(0,1));
      });completion.catch(()=>{});
      try {
        const deadline=Date.now()+5000;let marker;
        while(true){marker=await counters(prefix);if(marker.length)break;assert(Date.now()<deadline,'Initial upload authorization marker absent');assert.equal(responseStarted,false);await new Promise(resolve=>setTimeout(resolve,5));}
        assert.equal(marker.length,1);assert.equal(marker[0].count,1);const requestMarker=await counters(requestPrefix);assert.equal(requestMarker.length,1);assert.equal(requestMarker[0].count,1);
        assert.equal(responseStarted,false);assert.equal(released,false);assert.deepEqual(await quotaState(),before);
        // mediaRoutes increments this user-specific upload counter only after
        // initial project/premium/write authorization, before awaiting body bytes.
        if(kind==='logout') {
          await reservationHTTP('/auth/logout',{method:'POST',token:attempt.token,expected:{ok:true}});
          const revoked=await db.prepare('SELECT revoked_at,expires_at FROM sessions WHERE id=?').bind(attempt.id).first();assert.ok(Number.isInteger(revoked.revoked_at));assert.ok(revoked.revoked_at>=createdAt&&revoked.revoked_at<=Date.now());assert.ok(revoked.expires_at>Date.now());
          const live=await db.prepare('SELECT revoked_at,expires_at FROM sessions WHERE id=?').bind(retained.id).first();assert.equal(live.revoked_at,null);assert.ok(live.expires_at>Date.now());
        } else {
          await reservationHTTP(`/v1/teams/${teamId}/members/${userId}`,{method:'PATCH',json:{role:'viewer'},expected:{ok:true}});
          assert.equal((await db.prepare('SELECT role FROM team_members WHERE team_id=? AND user_id=?').bind(teamId,userId).first()).role,'viewer');
          const live=await db.prepare('SELECT revoked_at,expires_at FROM sessions WHERE id=?').bind(attempt.id).first();assert.equal(live.revoked_at,null);assert.ok(live.expires_at>Date.now());
        }
        assert.equal(responseStarted,false);released=true;outgoing.end(content.subarray(1));
        const rejected=await completion;assert.equal(rejected.status,409);assert.deepEqual(rejected.data,{error:{code:'upload_unavailable',message:'Access changed or another device is uploading this image. Refresh and retry.'}});
        assert.equal(rejected.headers['cache-control'],'no-store');assert.equal(rejected.headers['x-content-type-options'],'nosniff');assert.equal(rejected.headers['content-type'],'application/json; charset=utf-8');
        assert.deepEqual(await quotaState(),before);assert.deepEqual(await counters(prefix),marker);assert.deepEqual(await counters(requestPrefix),requestMarker);
        if(kind==='logout') {
          await reservationHTTP('/v1/me',{token:attempt.token,status:401,expected:{error:{code:'session_expired',message:'Your Scriv session has expired. Sign in again.'}}});
          assert.deepEqual(await counters(requestPrefix),requestMarker);
        } else {
          await reservationHTTP(asset,{...upload(attempt.token),status:402,expected:{error:{code:'team_subscription_required',message:'Hosted image storage requires an active Team subscription.'}}});
          assert.deepEqual(await quotaState(),before);assert.deepEqual(await counters(prefix),marker);
          await reservationHTTP(`/v1/teams/${teamId}/members/${userId}`,{method:'PATCH',json:{role:'member'},expected:{ok:true}});
          assert.equal((await db.prepare('SELECT role FROM team_members WHERE team_id=? AND user_id=?').bind(teamId,userId).first()).role,'member');
        }
        await reservationHTTP(asset,upload(retained.token));await readyReplica(hash,content,'image/png',userId);
        await reservationHTTP(asset,{method:'DELETE',expected:{ok:true}});assert.deepEqual(await quotaState(),before);
        reservationCases.push({kind,heldStatus:409,heldCode:'upload_unavailable',retryStatus:201});
      } finally {outgoing?.destroy();}
    }
    await interruptedUpload('logout');await interruptedUpload('downgrade');
    await db.prepare('UPDATE teams SET storage_limit=? WHERE id=?').bind(originalTeam.storage_limit,teamId).run();
    assert.deepEqual(await db.prepare('SELECT * FROM teams WHERE id=?').bind(teamId).first(),originalTeam);
    const finalMembers=(await db.prepare('SELECT * FROM team_members ORDER BY user_id').all()).results;
    assert.deepEqual(finalMembers.filter(m=>!addedUsers.includes(m.user_id)),originalMembers);assert.equal(finalMembers.length,originalMembers.length+2);
    assert.deepEqual(await mediaState(),{rows:[],objects:[]});assert.equal(requests-reservationStart,20);assert.equal(outboundAttempts,0);
    console.log(JSON.stringify({kind:'media-reservation-evidence',httpChecks:20,quotaBytes:12,cases:reservationCases,marker:'post-initial-authorization upload counter',sentBodyPrefixBytes:1,arbitraryRaceCoverage:false,nativeScenarios:0,outboundAttempts}));
    // Equal content in different projects must remain independently hosted and accounted.
    assert.equal(requests,83);const replicaStart=requests,replicaProject=randomUUID(),replicaTitle='Synthetic replica isolation';
    const replicaRows=async table=>(await db.prepare(`SELECT * FROM ${table} ORDER BY rowid`).all()).results;
    const replicaIdentity=async()=>({users:await replicaRows('users'),sessions:await replicaRows('sessions'),members:await replicaRows('team_members')});
    const replicaBaselineIdentity=await replicaIdentity(),replicaBaselineProjects=await replicaRows('projects'),replicaBaselineTeams=await replicaRows('teams');
    assert.deepEqual(await mediaState(),{rows:[],objects:[]});assert.equal(content.length,12);
    const replicaCreateStart=Date.now();let replicaResponse=await reservationHTTP('/v1/projects',{method:'POST',json:{id:replicaProject,title:replicaTitle,teamId},status:201});const replicaCreateEnd=Date.now();
    const replicaProjectRow=(await replicaRows('projects')).find(p=>p.id===replicaProject);assert(replicaProjectRow.created_at>=replicaCreateStart&&replicaProjectRow.created_at<=replicaCreateEnd);
    assert.deepEqual(replicaProjectRow,{id:replicaProject,title:replicaTitle,owner_id:actors.owner.id,team_id:teamId,created_at:replicaProjectRow.created_at,updated_at:replicaProjectRow.created_at,archived_at:null});
    assert.deepEqual(replicaResponse,{project:{id:replicaProject,title:replicaTitle,ownerId:actors.owner.id,teamId,createdAt:replicaProjectRow.created_at,updatedAt:replicaProjectRow.created_at,archivedAt:null}});
    const otherAsset=`/v1/projects/${replicaProject}/assets/${hash}`;
    async function replicaState(expectedBytes){
      const state=await mediaState(),teams=await replicaRows('teams');assert.deepEqual(teams,replicaBaselineTeams.map(t=>t.id===teamId?{...t,storage_used:expectedBytes}:t));return state;
    }
    function exactReplica(state,project,userId,start,end){
      const row=state.rows.find(r=>r.project_id===project);assert.ok(row);assert(row.created_at>=start&&row.created_at<=end);
      assert.match(row.object_key,new RegExp(`^projects/${project}/${hash}/[0-9a-f-]{36}$`));
      assert.deepEqual(row,{project_id:project,sha256:hash,team_id:teamId,asset_id:null,object_key:row.object_key,content_type:'image/png',bytes:12,state:'ready',uploaded_by:userId,created_at:row.created_at});
      const object=state.objects.find(o=>o.key===row.object_key);assert.deepEqual(object,{key:row.object_key,bytes:content.toString('hex'),contentType:'image/png',metadata:{sha256:hash,projectId:project,teamId}});return row;
    }
    async function replicaRead(path,{role='viewer',method='GET',status=200,expected,validator=false}={}){
      const base=await mf.ready,url=new URL(path,base);assert.equal(base.hostname,'127.0.0.1');assert.equal(base.protocol,'http:');assert.equal(url.origin,base.origin);assert(requests++<110);
      const response=await fetch(url,{method,headers:{authorization:`Bearer ${actors[role].token}`,...(validator?{'if-none-match':`"${hash}"`}:{})},redirect:'error',signal:AbortSignal.timeout(5000)});
      assert.equal(response.status,status);assert.equal(response.headers.get('x-content-type-options'),'nosniff');const parts=[];let size=0;const reader=response.body?.getReader();if(reader)while(true){const{done,value}=await reader.read();if(done)break;size+=value.length;assert(size<=16384);parts.push(value);}const received=Buffer.concat(parts);
      if(status===200){assert.equal(response.headers.get('content-type'),'image/png');assert.equal(response.headers.get('content-length'),'12');assert.equal(response.headers.get('cache-control'),'private, no-store');assert.equal(response.headers.get('etag'),`"${hash}"`);assert.equal(response.headers.get('x-scriv-sha256'),hash);assert.deepEqual(received,method==='HEAD'?Buffer.alloc(0):content);}
      else{assert.equal(response.headers.get('content-type'),'application/json; charset=utf-8');assert.equal(response.headers.get('cache-control'),'no-store');assert.equal(response.headers.get('etag'),null);assert.equal(response.headers.get('x-scriv-sha256'),null);if(method==='HEAD')assert.equal(received.length,0);else assert.deepEqual(JSON.parse(received.toString('utf8')),expected);}
    }
    let begin=Date.now();await reservationHTTP(asset,upload(actors.owner.token));let end=Date.now();const one=await replicaState(12),firstReplica=exactReplica(one,projectId,actors.owner.id,begin,end);assert.equal(one.rows.length,1);assert.equal(one.objects.length,1);
    begin=Date.now();await reservationHTTP(otherAsset,upload(actors.member.token));end=Date.now();const two=await replicaState(24),secondReplica=exactReplica(two,replicaProject,actors.member.id,begin,end);assert.equal(two.rows.length,2);assert.equal(two.objects.length,2);assert.notEqual(secondReplica.object_key,firstReplica.object_key);
    assert.deepEqual(two.rows.find(r=>r.project_id===projectId),firstReplica);assert.deepEqual(two.objects.find(o=>o.key===firstReplica.object_key),one.objects[0]);
    await reservationHTTP(asset,{...upload(actors.member.token),status:200});assert.deepEqual(await replicaState(24),two);
    replicaResponse=await reservationHTTP(`/v1/teams/${teamId}`,{token:actors.viewer.token});assert.equal(replicaResponse.team.storageUsed,24);
    for(const path of [asset,otherAsset]){await replicaRead(path);await replicaRead(path,{method:'HEAD'});assert.deepEqual(await replicaState(24),two);}
    const hiddenProject={error:{code:'not_found',message:'Project not found.'}};
    await replicaRead(asset,{role:'outsider',status:404,expected:hiddenProject,validator:true});await replicaRead(otherAsset,{role:'outsider',method:'HEAD',status:404,validator:true});assert.deepEqual(await replicaState(24),two);
    const deleteDenied={error:{code:'not_allowed',message:'Only an owner or administrator can delete hosted images.'}};
    await reservationHTTP(asset,{method:'DELETE',token:actors.viewer.token,status:403,expected:deleteDenied});await reservationHTTP(otherAsset,{method:'DELETE',token:actors.member.token,status:403,expected:deleteDenied});assert.deepEqual(await replicaState(24),two);
    await reservationHTTP(asset,{method:'DELETE',expected:{ok:true}});const onlyOther=await replicaState(12);assert.deepEqual(onlyOther,{rows:[secondReplica],objects:two.objects.filter(o=>o.key===secondReplica.object_key)});
    await replicaRead(asset,{status:404,expected:{error:{code:'asset_unavailable',message:'This image has no hosted copy. Request it from an online peer.'}}});await replicaRead(otherAsset);assert.deepEqual(await replicaState(12),onlyOther);
    await reservationHTTP(asset,{method:'DELETE',expected:{ok:true}});await reservationHTTP(otherAsset,{...upload(actors.owner.token),status:200});assert.deepEqual(await replicaState(12),onlyOther);
    begin=Date.now();await reservationHTTP(asset,upload(actors.owner.token));end=Date.now();const replaced=await replicaState(24),replacementReplica=exactReplica(replaced,projectId,actors.owner.id,begin,end);assert.notEqual(replacementReplica.object_key,firstReplica.object_key);assert.notEqual(replacementReplica.object_key,secondReplica.object_key);
    assert.equal(replaced.rows.length,2);assert.equal(replaced.objects.length,2);assert.deepEqual(replaced.rows.find(r=>r.project_id===replicaProject),secondReplica);assert.deepEqual(replaced.objects.find(o=>o.key===secondReplica.object_key),onlyOther.objects[0]);assert.equal(replaced.objects.some(o=>o.key===firstReplica.object_key),false);
    await replicaRead(asset,{validator:true});assert.deepEqual(await replicaState(24),replaced);
    await reservationHTTP(otherAsset,{method:'DELETE',expected:{ok:true}});assert.deepEqual(await replicaState(12),{rows:[replacementReplica],objects:replaced.objects.filter(o=>o.key===replacementReplica.object_key)});
    await reservationHTTP(asset,{method:'DELETE',expected:{ok:true}});assert.deepEqual(await replicaState(0),{rows:[],objects:[]});
    const archiveStart=Date.now();await reservationHTTP(`/v1/projects/${replicaProject}`,{method:'DELETE',expected:{ok:true}});const archiveEnd=Date.now();
    await reservationHTTP(`/v1/projects/${replicaProject}`,{status:404,expected:hiddenProject});const finalReplicaProjects=await replicaRows('projects'),archived=finalReplicaProjects.find(p=>p.id===replicaProject);
    assert(archived.archived_at>=archiveStart&&archived.archived_at<=archiveEnd);assert.deepEqual(archived,{...replicaProjectRow,updated_at:archived.archived_at,archived_at:archived.archived_at});assert.deepEqual(finalReplicaProjects.filter(p=>p.id!==replicaProject),replicaBaselineProjects);
    assert.deepEqual(await replicaRows('teams'),replicaBaselineTeams);assert.deepEqual(await replicaIdentity(),replicaBaselineIdentity);assert.deepEqual(await mediaState(),{rows:[],objects:[]});assert.equal(requests-replicaStart,24);assert.equal(requests,107);assert.equal(outboundAttempts,0);
    console.log(JSON.stringify({kind:'cross-project-replica-evidence',httpChecks:24,sharedHashProjects:2,peakReplicaBytes:24,independentObjectKeys:true,duplicateUploads:2,readPrivacyRefusals:2,deletePermissionRefusals:2,replacementKeyRotated:true,newProjectArchived:true,finalStorageBytes:0,internalInterleavingControlled:false,nativeScenarios:0,outboundAttempts}));
    console.log(JSON.stringify({ result: 'PASS', journey: 'discussions-assets', requests, mediaBoundaryCases: mediaCases, outboundAttempts, migrations: migrations.length, bundleSha256: createHash('sha256').update(await readFile(bundle)).digest('hex'), nativeScenarios: 0, loginFlowTested: false, fixture: 'four original synthetic users/sessions plus two upload users and three sessions; one synthetic active team' }));
  } finally { await mf.dispose(); }
}
