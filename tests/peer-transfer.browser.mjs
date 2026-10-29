import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { randomBytes, createHash } from 'node:crypto';
import { chromium } from 'playwright';

let browser, server, origin;
const resource = new URL('../apps/mac/Sources/ScrivApp/Resources/PeerTransfer/', import.meta.url);
before(async () => {
  server = createServer(async (req, res) => {
    const file = req.url === '/bridge.js' ? 'bridge.js' : 'bridge.html';
    res.setHeader('Content-Type', file.endsWith('.js') ? 'text/javascript' : 'text/html');
    res.end(await readFile(new URL(file, resource)));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
});
after(async () => { await browser?.close(); if(server) await new Promise(resolve => server.close(resolve)); });

async function pair({ holdSignals = false, cpu = 1, dropFirstSignal } = {}) {
  const context = await browser.newContext();
  await context.addInitScript(() => {
    const Native = RTCPeerConnection;
    globalThis.scrivRTC = [];
    globalThis.RTCPeerConnection = new Proxy(Native, { construct(target, args) {
      const pc = new target(...args), record = { pc, channels: [], events: [] };
      const note = event => record.events.push({event,signal:pc.signalingState,ice:pc.iceConnectionState,connection:pc.connectionState});
      for (const event of ['signalingstatechange','iceconnectionstatechange','icegatheringstatechange','connectionstatechange','negotiationneeded']) pc.addEventListener(event,()=>note(event));
      const create = pc.createDataChannel.bind(pc);
      pc.createDataChannel = (...values) => { const channel=create(...values);record.channels.push(channel);for(const event of ['open','close','error'])channel.addEventListener(event,()=>note('channel:'+event));return channel; };
      globalThis.scrivRTC.push(record);return pc;
    }});
  });
  const pages = { alice: await context.newPage(), bob: await context.newPage() };
  const throttle = Math.max(cpu, Number(process.env.SCRIV_PEER_CPU ?? 1));
  if (throttle > 1) for (const page of Object.values(pages)) await (await context.newCDPSession(page)).send('Emulation.setCPUThrottlingRate',{rate:Math.min(8,throttle)});
  const events = { alice: [], bob: [] }, assets = { alice: new Map(), bob: new Map() };
  const failures = [];
  const held = [];
  let paused = holdSignals;
  let dropped = false;
  const deliver = async (from, event) => pages[event.toDeviceId].evaluate(async signal => await ScrivPeer.handleSignal(signal), { fromDeviceId: from, type: event.type, payload: event.payload });
  for (const [id,page] of Object.entries(pages)) {
    await page.exposeFunction('scrivPeerTestSink', async event => {
      events[id].push(event);
      try {
        if (event.kind === 'signal') {
          if (!dropped && event.type === dropFirstSignal) { dropped = true; return; }
          // Hold every signal until both requesters exist. Holding only offers
          // can accidentally create a passive peer through earlier ICE delivery.
          if (paused) held.push({ id, event });
          else await deliver(id, event);
        } else if (event.kind === 'request') {
          const data = assets[id].get(event.hash);
          await page.evaluate(async request => await ScrivPeer.provideAsset(request.peer, request.hash, request.data), { peer: event.fromDeviceId, hash: event.hash, data: data?.toString('base64') ?? null });
        }
      } catch(e) { failures.push(e); }
    });
    await page.goto(origin);
    await page.evaluate(deviceId => ScrivPeer.configure({deviceId,iceServers:[]}), id);
  }
  const releaseSignals = async () => {
    // Deliberately deliver initial candidates before SDP to cover unordered HTTP
    // signaling. The media itself still crosses actual browser WebRTC channels.
    const pending = held.splice(0);
    for (const signal of pending.filter(s => s.event.type === 'ice')) await deliver(signal.id, signal.event);
    paused = false;
    for (const signal of [...pending.filter(s => s.event.type !== 'ice'), ...held.splice(0)]) await deliver(signal.id, signal.event);
  };
  return {pages,events,assets,failures,held,releaseSignals,close:()=>context.close()};
}
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
async function waitFor(predicate, milliseconds=15000) {
  const until = Date.now()+milliseconds;
  while (Date.now()<until) { const result=predicate();if(result)return result;await new Promise(resolve=>setTimeout(resolve,20)); }
  throw new Error('Timed out waiting for a peer event.');
}
test('actual encrypted WebRTC channel transfers multi-chunk media with content integrity', {timeout:25000}, async () => {
  const p=await pair();
  try {
    const bytes=randomBytes(750321), hash=sha(bytes);p.assets.bob.set(hash,bytes);
    await p.pages.alice.evaluate(hash=>ScrivPeer.requestAsset(hash,'bob'),hash);
    const received=await waitFor(()=>p.events.alice.find(e=>e.kind==='asset'));
    assert.deepEqual(Buffer.from(received.base64,'base64'),bytes);
    assert.equal(received.hash,hash);assert.deepEqual(p.failures,[]);
    assert.ok(p.events.alice.some(e=>e.kind==='connected'));
    assert.ok(p.events.alice.filter(e=>e.kind==='signal').every(e=>!('base64' in e.payload)));
  } finally {await p.close();}
});
test('the higher-ID requester asks the lower-ID device to offer and receives its image', {timeout:25000}, async () => {
  const p=await pair();
  try {
    const bytes=randomBytes(250321), hash=sha(bytes);p.assets.alice.set(hash,bytes);
    await p.pages.bob.evaluate(hash=>ScrivPeer.requestAsset(hash,'alice'),hash);
    const received=await waitFor(()=>p.events.bob.find(e=>e.kind==='asset'));
    assert.deepEqual(Buffer.from(received.base64,'base64'),bytes);
    const connection=p.events.bob.find(e=>e.kind==='signal'&&e.type==='asset-request');
    assert.equal(connection?.payload.action,'connect');
    assert.match(connection.payload.requestId,/^[a-f0-9-]{36}$/);
    assert.equal(p.events.alice.filter(e=>e.kind==='signal'&&e.type==='offer').length,1);
    assert.equal(p.events.bob.filter(e=>e.kind==='signal'&&e.type==='offer').length,0);
    assert.deepEqual(p.failures,[]);
  } finally {await p.close();}
});
test('simultaneous and staggered image requests use one offer, including slow CPUs and ICE before SDP', {timeout:45000}, async () => {
  const scenarios=[{holdSignals:true,delay:0},{delay:0},{delay:1,cpu:4},{delay:5,cpu:4},{delay:20}];
  const repeats=Math.min(20,Math.max(1,Number(process.env.SCRIV_PEER_REPEATS??1)));
  for (const scenario of Array.from({length:repeats},()=>scenarios).flat()) {
    const p=await pair(scenario);
    try {
    const a=randomBytes(32123), b=randomBytes(83129), ha=sha(a), hb=sha(b);p.assets.alice.set(ha,a);p.assets.bob.set(hb,b);
    await Promise.all([p.pages.alice.evaluate(hash=>ScrivPeer.requestAsset(hash,'bob'),hb),(async()=>{if(scenario.delay)await new Promise(resolve=>setTimeout(resolve,scenario.delay));await p.pages.bob.evaluate(hash=>ScrivPeer.requestAsset(hash,'alice'),ha);})()]);
    if(scenario.holdSignals) {
      await waitFor(()=>p.held.some(s=>s.event.type==='offer')&&p.held.some(s=>s.event.type==='ice'));
      await p.releaseSignals();
    }
    const receivedA=await waitFor(()=>p.events.alice.find(e=>e.kind==='asset'));
    const receivedB=await waitFor(()=>p.events.bob.find(e=>e.kind==='asset'));
    assert.deepEqual(Buffer.from(receivedA.base64,'base64'),b);
    assert.deepEqual(Buffer.from(receivedB.base64,'base64'),a);
    assert.deepEqual(p.failures,[]);
    assert.equal(p.events.alice.filter(e=>e.kind==='signal'&&e.type==='offer').length,1);
    assert.equal(p.events.bob.filter(e=>e.kind==='signal'&&e.type==='offer').length,0);
    } catch (error) {
      error.message += '\nScenario: '+JSON.stringify(scenario)+'\nNegotiation failures: ' + p.failures.map(e=>e.message).join('; ') + '\nPeer errors: ' + JSON.stringify(Object.fromEntries(Object.entries(p.events).map(([id,events])=>[id,events.filter(e=>e.kind==='error')])));
      const states=await Promise.all(Object.entries(p.pages).map(async([id,page])=>[id,await page.evaluate(()=>globalThis.scrivRTC.map(({pc,channels,events})=>({signaling:pc.signalingState,ice:pc.iceConnectionState,gathering:pc.iceGatheringState,connection:pc.connectionState,sctp:pc.sctp?.state,local:pc.localDescription?.type,remote:pc.remoteDescription?.type,localTransport:pc.localDescription?.sdp.match(/^(?:m=|a=ice-ufrag:|a=setup:).+$/gm),remoteTransport:pc.remoteDescription?.sdp.match(/^(?:m=|a=ice-ufrag:|a=setup:).+$/gm),channels:channels.map(c=>({id:c.id,state:c.readyState,buffered:c.bufferedAmount})),events}))) ]));
      error.message+='\nRTC states: '+JSON.stringify(Object.fromEntries(states));
      throw error;
    } finally {await p.close();}
  }
});
test('offline asset, invalid hash and unsolicited transfer fail explicitly', {timeout:25000}, async () => {
  const p=await pair();
  try {
    await assert.rejects(()=>p.pages.alice.evaluate(()=>ScrivPeer.requestAsset('../secret','bob')),/Invalid image hash/);
    const missing=sha(Buffer.from('missing'));
    await p.pages.alice.evaluate(hash=>ScrivPeer.requestAsset(hash,'bob'),missing);
    const absent=await waitFor(()=>p.events.alice.find(e=>e.kind==='error'&&e.hash===missing));
    assert.match(absent.message,/does not have/);
    const unsolicited=randomBytes(80), hash=sha(unsolicited);
    await p.pages.bob.evaluate(async value=>await ScrivPeer.provideAsset('alice',value.hash,value.base64),{hash,base64:unsolicited.toString('base64')});
    const rejected=await waitFor(()=>p.events.alice.find(e=>e.kind==='error'&&/Unrequested/.test(e.message)));
    assert.ok(rejected);assert.equal(p.events.alice.filter(e=>e.kind==='asset').length,0);
  } finally {await p.close();}
});
test('a closed peer reconnects without stale channel callbacks cancelling its new transfer', {timeout:30000}, async () => {
  const p=await pair();
  try {
    const first=randomBytes(48213), firstHash=sha(first);p.assets.alice.set(firstHash,first);
    await p.pages.bob.evaluate(hash=>ScrivPeer.requestAsset(hash,'alice'),firstHash);
    await waitFor(()=>p.events.bob.find(e=>e.kind==='asset'&&e.hash===firstHash));
    await p.pages.alice.evaluate(()=>{ScrivPeer.disconnect();ScrivPeer.configure({deviceId:'alice',iceServers:[]});});
    await waitFor(()=>p.events.bob.find(e=>e.kind==='disconnected'));
    const next=randomBytes(67291), nextHash=sha(next);p.assets.alice.set(nextHash,next);
    await p.pages.bob.evaluate(hash=>ScrivPeer.requestAsset(hash,'alice'),nextHash);
    const received=await waitFor(()=>p.events.bob.find(e=>e.kind==='asset'&&e.hash===nextHash));
    assert.deepEqual(Buffer.from(received.base64,'base64'),next);
    assert.deepEqual(p.failures,[]);
    assert.equal(p.events.bob.filter(e=>e.kind==='connected').length,2);
    const attempts=p.events.bob.filter(e=>e.kind==='signal'&&e.type==='asset-request').map(e=>e.payload.requestId);
    assert.equal(attempts.length,2);assert.equal(new Set(attempts).size,2);
  } finally {await p.close();}
});
test('either requester can retry after a dropped connect request, offer or answer', {timeout:45000}, async () => {
  const scenarios=[{type:'asset-request',requester:'bob'},{type:'offer',requester:'bob'},{type:'answer',requester:'bob'},{type:'offer',requester:'alice'},{type:'answer',requester:'alice'}];
  for (const {type,requester} of scenarios) {
    const p=await pair({dropFirstSignal:type});
    try {
      const owner=requester==='alice'?'bob':'alice';
      const bytes=randomBytes(54219), hash=sha(bytes);p.assets[owner].set(hash,bytes);
      // Advance only the JavaScript request deadline; transport and all media
      // continue to use the real browser's native RTCPeerConnection.
      await p.pages[requester].clock.install();
      await p.pages[requester].evaluate(({hash,owner})=>ScrivPeer.requestAsset(hash,owner),{hash,owner});
      await waitFor(()=>Object.values(p.events).some(events=>events.some(e=>e.kind==='signal'&&e.type===type)));
      await p.pages[requester].clock.fastForward(60001);
      await waitFor(()=>p.events[requester].some(e=>e.kind==='error'&&e.hash===hash&&/timed out/.test(e.message)));
      await p.pages[requester].evaluate(({hash,owner})=>ScrivPeer.requestAsset(hash,owner),{hash,owner});
      const received=await waitFor(()=>p.events[requester].find(e=>e.kind==='asset'&&e.hash===hash));
      assert.deepEqual(Buffer.from(received.base64,'base64'),bytes);
      assert.deepEqual(p.failures,[]);
      assert.equal(Object.values(p.events).flat().filter(e=>e.kind==='signal'&&e.type===type).length,2);
    } finally {await p.close();}
  }
});
