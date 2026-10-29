// Deterministic protocol/state regressions; the separate browser suite verifies
// actual WebRTC. This fake transport is not evidence of network connectivity.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash, webcrypto} from 'node:crypto';
import vm from 'node:vm';
const source = await readFile(new URL('../apps/mac/Sources/ScrivApp/Resources/PeerTransfer/bridge.js', import.meta.url), 'utf8');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const drain = () => new Promise(resolve => setImmediate(resolve));
function fixture({digest = (...args) => webcrypto.subtle.digest(...args)} = {}) {
  const events = [], channels = [], listeners = new Set();
  const accept = event => { events.push(event); for (const listener of [...listeners]) listener(event); };
  class Channel {
    label = 'scriv-media'; readyState = 'open'; bufferedAmount = 0; sent = [];
    send(data) { this.sent.push(data); }
    close() { this.readyState = 'closed'; this.onclose?.(); }
    receive(data) { this.onmessage?.({data}); }
  }
  class Peer {
    createDataChannel() { const channel = new Channel(); channels.push(channel); return channel; }
    close() {}
  }
  const context = vm.createContext({RTCPeerConnection:Peer, crypto:{randomUUID:()=>webcrypto.randomUUID(), subtle:{digest}}, Uint8Array, ArrayBuffer, setTimeout, clearTimeout, btoa, atob, scrivPeerTestSink:accept});
  vm.runInContext(source, context);
  context.ScrivPeer.configure({deviceId:'alice', iceServers:[]});
  function waitForEvent(predicate) {
    const existing = events.find(predicate);
    if (existing) return Promise.resolve(existing);
    return bounded(new Promise(resolve => {
      const listener = event => { if (predicate(event)) { listeners.delete(listener); resolve(event); } };
      listeners.add(listener);
    }), 'Expected peer event was not observed');
  }
  return {api:context.ScrivPeer, channels, events, waitForEvent, close:()=>context.ScrivPeer.disconnect()};
}
function transfer(channel, hash, bytes) {
  channel.receive(JSON.stringify({type:'begin', hash, bytes:bytes.length}));
  channel.receive(Uint8Array.from(bytes).buffer);
  channel.receive(JSON.stringify({type:'end', hash}));
}
// Await the actual event/deferred checksum, not a number of event-loop turns.
// WebCrypto runs on a worker pool and can legitimately complete after hundreds
// of setImmediate callbacks when the aggregate suite or compiler is busy.
function bounded(promise, message) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), 5000); })]).finally(() => clearTimeout(timer));
}
test('peer state machine verifies requested data and rejects corrupt bytes', async () => {
  for (const corrupt of [false, true]) {
    const p = fixture();
    try {
      const bytes = Buffer.from('real checksum, simulated channel'), hash = sha(bytes);
      await p.api.requestAsset(hash, 'bob');
      const payload = Buffer.from(bytes); if (corrupt) payload[0] ^= 1;
      transfer(p.channels[0], hash, payload);
      await p.waitForEvent(e=>e.kind===(corrupt?'error':'asset'));
      if (corrupt) { assert.equal(p.events.filter(e=>e.kind==='asset').length,0); assert.ok(p.events.some(e=>/integrity/.test(e.message))); }
      else assert.deepEqual(Buffer.from(p.events.find(e=>e.kind==='asset').base64, 'base64'), bytes);
    } finally { p.close(); }
  }
});
test('retired checksum cannot consume a new request for the same peer and hash', async () => {
  let release, first = true, checksumStarted;
  const firstChecksum = new Promise(resolve => { checksumStarted = resolve; });
  const p = fixture({digest:async (...args)=>{
    const result = await webcrypto.subtle.digest(...args);
    if (first) { first = false; await new Promise(resolve=>{release=resolve; checksumStarted();}); }
    return result;
  }});
  try {
    const bytes = Buffer.from('retain exactly one current transfer'), hash = sha(bytes);
    await p.api.requestAsset(hash,'bob'); transfer(p.channels[0], hash, bytes);
    await bounded(firstChecksum, 'The deferred checksum did not start');
    p.api.disconnect(); p.api.configure({deviceId:'alice', iceServers:[]});
    await p.api.requestAsset(hash,'bob'); release();
    await drain();
    assert.equal(p.events.filter(e=>e.kind==='asset').length,0);
    transfer(p.channels.at(-1), hash, bytes);
    await p.waitForEvent(e=>e.kind==='asset');
    assert.equal(p.events.filter(e=>e.kind==='asset').length,1);
  } finally { p.close(); }
});
test('peer requests remain idempotent when all request slots are occupied', async () => {
  const p = fixture();
  try {
    const hashes=Array.from({length:8},(_,i)=>sha(Buffer.from(String(i))));
    for (const hash of hashes) await p.api.requestAsset(hash,'bob');
    await p.api.requestAsset(hashes[0],'bob');
    assert.equal(p.channels[0].sent.length,8);
    await assert.rejects(()=>p.api.requestAsset(sha(Buffer.from('ninth')),'bob'),/Too many image requests/);
  } finally { p.close(); }
});
test('invalid peer configuration and signal do not allocate or alter a transport', async () => {
  const p = fixture();
  try {
    for (const maxBytes of [0,-1,NaN,Infinity,1.1]) assert.throws(()=>p.api.configure({deviceId:'changed',maxBytes}),/Invalid peer configuration/);
    await assert.rejects(()=>p.api.handleSignal({fromDeviceId:'bob',type:'query',payload:{}}),/Unsupported peer signal/);
    assert.equal(p.channels.length,0);
    // A failed configure must leave the original identity intact.
    await assert.rejects(()=>p.api.requestAsset(sha(Buffer.from('x')),'alice'),/Invalid peer identity/);
    assert.equal(p.channels.length,0);
  } finally { p.close(); }
});
test('unrequested unavailable messages do not report a failed requested image', async () => {
  const p = fixture();
  try {
    const wanted=sha(Buffer.from('wanted')), other=sha(Buffer.from('other'));
    await p.api.requestAsset(wanted,'bob');
    p.channels[0].receive(JSON.stringify({type:'unavailable',hash:other})); await drain();
    assert.equal(p.events.filter(e=>e.kind==='error').length,0);
    p.channels[0].receive(JSON.stringify({type:'unavailable',hash:wanted})); await drain();
    assert.equal(p.events.filter(e=>e.kind==='error'&&e.hash===wanted).length,1);
  } finally { p.close(); }
});
