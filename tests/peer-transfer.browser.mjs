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

async function pair({ collide = false } = {}) {
  const context = await browser.newContext();
  const pages = { alice: await context.newPage(), bob: await context.newPage() };
  const events = { alice: [], bob: [] }, assets = { alice: new Map(), bob: new Map() };
  const failures = [];
  const offers = [];
  let collisionReleased = false;
  const deliver = async (from, event) => pages[event.toDeviceId].evaluate(async signal => await ScrivPeer.handleSignal(signal), { fromDeviceId: from, type: event.type, payload: event.payload });
  for (const [id,page] of Object.entries(pages)) {
    await page.exposeFunction('scrivPeerTestSink', async event => {
      events[id].push(event);
      try {
        if (event.kind === 'signal') {
          // Force both local offers to exist before delivering either. ICE can
          // arrive first, as it can with independent HTTP signaling requests.
          if (collide && !collisionReleased && event.type === 'offer') {
            offers.push({ id, event });
            if (offers.length === 2) {
              collisionReleased = true;
              await Promise.all(offers.map(offer => deliver(offer.id, offer.event)));
            }
          } else await deliver(id, event);
        } else if (event.kind === 'request') {
          const data = assets[id].get(event.hash);
          await page.evaluate(async request => await ScrivPeer.provideAsset(request.peer, request.hash, request.data), { peer: event.fromDeviceId, hash: event.hash, data: data?.toString('base64') ?? null });
        }
      } catch(e) { failures.push(e); }
    });
    await page.goto(origin);
    await page.evaluate(deviceId => ScrivPeer.configure({deviceId,iceServers:[]}), id);
  }
  return {pages,events,assets,failures,close:()=>context.close()};
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
test('two Macs requesting at once resolve offer collision without losing either image', {timeout:45000}, async () => {
  for (const scenario of [{collide:true,delay:0},{collide:false,delay:0},{collide:false,delay:1},{collide:false,delay:5},{collide:false,delay:20}]) {
    const p=await pair(scenario);
    try {
    const a=randomBytes(32123), b=randomBytes(83129), ha=sha(a), hb=sha(b);p.assets.alice.set(ha,a);p.assets.bob.set(hb,b);
    await Promise.all([p.pages.alice.evaluate(hash=>ScrivPeer.requestAsset(hash,'bob'),hb),(async()=>{if(scenario.delay)await new Promise(resolve=>setTimeout(resolve,scenario.delay));await p.pages.bob.evaluate(hash=>ScrivPeer.requestAsset(hash,'alice'),ha);})()]);
    const receivedA=await waitFor(()=>p.events.alice.find(e=>e.kind==='asset'));
    const receivedB=await waitFor(()=>p.events.bob.find(e=>e.kind==='asset'));
    assert.deepEqual(Buffer.from(receivedA.base64,'base64'),b);
    assert.deepEqual(Buffer.from(receivedB.base64,'base64'),a);
    assert.deepEqual(p.failures,[]);
    } catch (error) {
      error.message += '\nScenario: '+JSON.stringify(scenario)+'\nNegotiation failures: ' + p.failures.map(e=>e.message).join('; ') + '\nPeer errors: ' + JSON.stringify(Object.fromEntries(Object.entries(p.events).map(([id,events])=>[id,events.filter(e=>e.kind==='error')])));
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
