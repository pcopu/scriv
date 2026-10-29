/* Local-only WebKit transport. Signaling is authenticated by Scriv Cloud; media is
 * DTLS-encrypted by WebRTC. This page never receives account or Codex credentials. */
(() => {
  'use strict';
  const CHUNK = 16 * 1024;
  const HARD_LIMIT = 25 * 1024 * 1024;
  const HASH = /^[a-f0-9]{64}$/;
  const peers = new Map();
  const requested = new Map();
  let identity = '', iceServers = [], maxBytes = HARD_LIMIT;
  const emit = value => {
    if (globalThis.webkit?.messageHandlers?.scrivPeer) globalThis.webkit.messageHandlers.scrivPeer.postMessage(value);
    else if (typeof globalThis.scrivPeerTestSink === 'function') globalThis.scrivPeerTestSink(value);
  };
  const key = (peer, hash) => `${peer}:${hash}`;
  const error = (peer, hash, message) => {
    const pending = requested.get(key(peer, hash));
    if (pending) clearTimeout(pending.timer);
    requested.delete(key(peer, hash));
    emit({ kind: 'error', fromDeviceId: peer, hash, message });
  };
  function encode(bytes) {
    let result = '';
    for (let i = 0; i < bytes.length; i += CHUNK) result += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
    return btoa(result);
  }
  function decode(base64) {
    const binary = atob(base64), bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }
  async function digest(bytes) {
    const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
    return Array.from(hash, b => b.toString(16).padStart(2, '0')).join('');
  }
  function signal(peer, type, payload) { emit({ kind: 'signal', toDeviceId: peer.id, type, payload }); }
  function flush(peer) {
    if (peer.channel?.readyState !== 'open') return;
    for (const pending of requested.values()) {
      if (pending.peer === peer.id && !pending.sent) {
        peer.channel.send(JSON.stringify({ type: 'request', hash: pending.hash }));
        pending.sent = true;
      }
    }
  }
  function attach(peer, channel) {
    if (channel.label !== 'scriv-media') { channel.close(); return; }
    if (peer.channel && peer.channel !== channel && peer.channel.readyState === 'open') { channel.close(); return; }
    peer.channel = channel; channel.binaryType = 'arraybuffer'; channel.bufferedAmountLowThreshold = 64 * 1024;
    channel.onopen = () => { emit({ kind: 'connected', fromDeviceId: peer.id }); flush(peer); };
    channel.onclose = () => {
      if (peer.channel !== channel) return;
      for (const pending of Array.from(requested.values())) if (pending.peer === peer.id) error(peer.id, pending.hash, 'Peer disconnected. Try another device or the hosted copy.');
      peer.receiving = null;
    };
    channel.onerror = () => emit({ kind: 'error', fromDeviceId: peer.id, message: 'The encrypted peer channel failed.' });
    channel.onmessage = event => {
      peer.receiveQueue = peer.receiveQueue.then(() => receive(peer, event.data)).catch(e => {
        error(peer.id, peer.receiving?.hash ?? '', e.message); peer.receiving = null; channel.close();
      });
    };
  }
  function ensurePeer(id, initiator = false) {
    if (typeof id !== 'string' || !id || id.length > 128 || id === identity) throw new Error('Invalid peer identity.');
    if (peers.has(id)) return peers.get(id);
    if (peers.size >= 8) throw new Error('Too many active peer transfers.');
    const peer = { id, pc: new RTCPeerConnection({ iceServers }), channel: null, makingOffer: false, ignoreOffer: false, isSettingRemoteAnswerPending: false, candidates: [], receiving: null, receiveQueue: Promise.resolve(), sendQueue: Promise.resolve() };
    peers.set(id, peer);
    peer.pc.onicecandidate = event => { if (event.candidate) signal(peer, 'ice', event.candidate.toJSON()); };
    peer.pc.ondatachannel = event => attach(peer, event.channel);
    peer.pc.onnegotiationneeded = async () => {
      // This connection has one fixed negotiated channel. A peer constructed by
      // incoming ICE/SDP must answer that offer instead of racing it with another
      // initial offer. A requester starts negotiation once; failed peers rebuild.
      if (!initiator || peer.pc.localDescription || peer.pc.remoteDescription) return;
      try { peer.makingOffer = true; await peer.pc.setLocalDescription(); signal(peer, peer.pc.localDescription.type, peer.pc.localDescription.toJSON()); }
      catch (e) { emit({ kind: 'error', fromDeviceId: id, message: e.message }); }
      finally { peer.makingOffer = false; }
    };
    peer.pc.onconnectionstatechange = () => {
      if (['failed', 'closed'].includes(peer.pc.connectionState)) {
        for (const pending of Array.from(requested.values())) if (pending.peer === id) error(id, pending.hash, 'Peer unavailable. TURN may be needed on this network.');
        peer.pc.close(); peers.delete(id);
      }
    };
    // A negotiated channel has the same ID at both ends, including when two Macs
    // request images simultaneously. Perfect negotiation below resolves offer glare.
    attach(peer, peer.pc.createDataChannel('scriv-media', { ordered: true, negotiated: true, id: 0 }));
    return peer;
  }
  async function receive(peer, data) {
    if (typeof data !== 'string') {
      const transfer = peer.receiving;
      if (!transfer || !(data instanceof ArrayBuffer)) throw new Error('Unexpected media data.');
      if (transfer.received + data.byteLength > transfer.bytes || data.byteLength > CHUNK) throw new Error('Invalid media chunk size.');
      transfer.data.set(new Uint8Array(data), transfer.received); transfer.received += data.byteLength;
      return;
    }
    if (data.length > 4096) throw new Error('Peer control message too large.');
    const message = JSON.parse(data);
    if (!HASH.test(message.hash ?? '')) throw new Error('Invalid content hash.');
    if (message.type === 'request') {
      emit({ kind: 'request', fromDeviceId: peer.id, hash: message.hash });
    } else if (message.type === 'unavailable') {
      error(peer.id, message.hash, 'That device does not have the requested image.');
    } else if (message.type === 'begin') {
      if (!requested.has(key(peer.id, message.hash)) || peer.receiving || !Number.isSafeInteger(message.bytes) || message.bytes < 1 || message.bytes > maxBytes) throw new Error('Unrequested or oversized image.');
      peer.receiving = { hash: message.hash, bytes: message.bytes, received: 0, data: new Uint8Array(message.bytes) };
    } else if (message.type === 'end') {
      const transfer = peer.receiving; peer.receiving = null;
      if (!transfer || transfer.hash !== message.hash || transfer.received !== transfer.bytes) throw new Error('Incomplete image transfer.');
      if (await digest(transfer.data) !== message.hash) throw new Error('Image integrity check failed.');
      const pending = requested.get(key(peer.id, message.hash));
      if (!pending) throw new Error('Transfer expired.');
      clearTimeout(pending.timer); requested.delete(key(peer.id, message.hash));
      emit({ kind: 'asset', fromDeviceId: peer.id, hash: message.hash, base64: encode(transfer.data) });
    } else throw new Error('Unsupported peer control message.');
  }
  async function backpressure(channel) {
    if (channel.readyState !== 'open') throw new Error('Peer channel closed.');
    if (channel.bufferedAmount <= 256 * 1024) return;
    await new Promise((resolve, reject) => {
      const done = () => { clearTimeout(timer); channel.removeEventListener('bufferedamountlow', low); channel.removeEventListener('close', closed); };
      const low = () => { done(); resolve(); }, closed = () => { done(); reject(new Error('Peer disconnected.')); };
      const timer = setTimeout(() => { done(); reject(new Error('Peer transfer stalled.')); }, 15000);
      channel.addEventListener('bufferedamountlow', low); channel.addEventListener('close', closed);
    });
  }
  async function addCandidate(peer, candidate) {
    // Candidates may arrive before SDP over HTTP or belong to a rolled-back
    // offer. Never feed an old ICE generation into the accepted description.
    const ufrag = candidate.usernameFragment;
    const active = peer.pc.remoteDescription?.sdp.match(/^a=ice-ufrag:(.+)$/gm)?.map(line => line.slice(12).trim()) ?? [];
    if (ufrag && active.length && !active.includes(ufrag)) return;
    try { await peer.pc.addIceCandidate(candidate); }
    catch (e) { if (!peer.ignoreOffer) throw e; }
  }
  globalThis.ScrivPeer = Object.freeze({
    configure(options) {
      if (peers.size) throw new Error('Disconnect transfers before changing identity.');
      identity = options.deviceId; iceServers = options.iceServers ?? [];
      maxBytes = Math.min(HARD_LIMIT, options.maxBytes ?? HARD_LIMIT);
      if (!identity || !Array.isArray(iceServers)) throw new Error('Invalid peer configuration.');
    },
    async requestAsset(hash, fromDeviceId) {
      if (!HASH.test(hash)) throw new Error('Invalid image hash.');
      if (requested.size >= 8) throw new Error('Too many image requests.');
      if (requested.has(key(fromDeviceId, hash))) return;
      const pending = { peer: fromDeviceId, hash, sent: false, timer: setTimeout(() => error(fromDeviceId, hash, 'Peer transfer timed out.'), 60000) };
      requested.set(key(fromDeviceId, hash), pending);
      try { const peer = ensurePeer(fromDeviceId, true); flush(peer); }
      catch (e) { error(fromDeviceId, hash, e.message); throw e; }
    },
    async handleSignal(message) {
      const peer = ensurePeer(message.fromDeviceId);
      if (message.type === 'ice') {
        if (!peer.pc.remoteDescription) {
          if (peer.candidates.length >= 128) throw new Error('Too many pending ICE candidates.');
          peer.candidates.push(message.payload);
        } else await addCandidate(peer, message.payload);
      } else if (message.type === 'offer' || message.type === 'answer') {
        const description = message.payload;
        if (description.type !== message.type || typeof description.sdp !== 'string' || description.sdp.length > 65536) throw new Error('Invalid peer description.');
        // W3C perfect negotiation: an answer being applied already queues the
        // connection back to stable, even before signalingState reflects it.
        const readyForOffer = !peer.makingOffer && (peer.pc.signalingState === 'stable' || peer.isSettingRemoteAnswerPending);
        const collision = description.type === 'offer' && !readyForOffer;
        peer.ignoreOffer = identity.localeCompare(peer.id) < 0 && collision;
        if (peer.ignoreOffer) return;
        peer.isSettingRemoteAnswerPending = description.type === 'answer';
        try { await peer.pc.setRemoteDescription(description); }
        finally { peer.isSettingRemoteAnswerPending = false; }
        for (const candidate of peer.candidates.splice(0)) await addCandidate(peer, candidate);
        if (description.type === 'offer') { await peer.pc.setLocalDescription(); signal(peer, peer.pc.localDescription.type, peer.pc.localDescription.toJSON()); }
      }
    },
    async provideAsset(peerId, hash, base64) {
      const peer = peers.get(peerId);
      if (!peer?.channel || peer.channel.readyState !== 'open' || !HASH.test(hash)) throw new Error('Peer not connected.');
      peer.sendQueue = peer.sendQueue.catch(() => {}).then(async () => {
        const channel = peer.channel;
        if (base64 === null) { channel.send(JSON.stringify({ type: 'unavailable', hash })); return; }
        if (base64.length > Math.ceil(maxBytes / 3) * 4) throw new Error('Image too large.');
        const bytes = decode(base64);
        if (!bytes.length || bytes.length > maxBytes || await digest(bytes) !== hash) throw new Error('Local image integrity check failed.');
        channel.send(JSON.stringify({ type: 'begin', hash, bytes: bytes.length }));
        for (let offset = 0; offset < bytes.length; offset += CHUNK) { await backpressure(channel); channel.send(bytes.subarray(offset, offset + CHUNK)); }
        channel.send(JSON.stringify({ type: 'end', hash }));
      });
      return peer.sendQueue;
    },
    disconnect() {
      for (const pending of requested.values()) clearTimeout(pending.timer);
      requested.clear();
      for (const peer of peers.values()) { peer.channel?.close(); peer.pc.close(); }
      peers.clear();
    }
  });
  emit({ kind: 'ready' });
})();
