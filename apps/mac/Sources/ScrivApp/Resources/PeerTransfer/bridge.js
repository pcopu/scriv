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
  function signal(peer, type, payload) { if (peers.get(peer.id) === peer) emit({ kind: 'signal', toDeviceId: peer.id, type, payload }); }
  function retire(peer, message) {
    if (peers.get(peer.id) !== peer) return;
    peers.delete(peer.id);
    for (const pending of Array.from(requested.values())) if (pending.peer === peer.id) error(peer.id, pending.hash, message);
    peer.receiving = null;
    peer.channel?.close(); peer.pc.close();
    emit({ kind: 'disconnected', fromDeviceId: peer.id });
  }
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
    channel.onopen = () => { if (peers.get(peer.id) !== peer || peer.channel !== channel) return; emit({ kind: 'connected', fromDeviceId: peer.id }); flush(peer); };
    channel.onclose = () => {
      if (peers.get(peer.id) !== peer || peer.channel !== channel) return;
      retire(peer, 'Peer disconnected. Try another device or the hosted copy.');
    };
    channel.onerror = () => { if (peers.get(peer.id) === peer) emit({ kind: 'error', fromDeviceId: peer.id, message: 'The encrypted peer channel failed.' }); };
    channel.onmessage = event => {
      if (peers.get(peer.id) !== peer || peer.channel !== channel) return;
      peer.receiveQueue = peer.receiveQueue.then(() => receive(peer, event.data)).catch(e => {
        if (peers.get(peer.id) !== peer) return;
        error(peer.id, peer.receiving?.hash ?? '', e.message); peer.receiving = null; channel.close();
      });
    };
  }
  function ensurePeer(id) {
    if (typeof id !== 'string' || !id || id.length > 128 || id === identity) throw new Error('Invalid peer identity.');
    if (peers.has(id)) return peers.get(id);
    if (peers.size >= 8) throw new Error('Too many active peer transfers.');
    const peer = { id, pc: new RTCPeerConnection({ iceServers }), channel: null, offerer: identity < id, makingOffer: false, connectionRequested: false, requestId: crypto.randomUUID(), remoteConnectId: null, candidates: [], receiving: null, signalQueue: Promise.resolve(), receiveQueue: Promise.resolve(), sendQueue: Promise.resolve() };
    peers.set(id, peer);
    peer.pc.onicecandidate = event => { if (event.candidate && peers.get(id) === peer) signal(peer, 'ice', event.candidate.toJSON()); };
    peer.pc.ondatachannel = event => { if (peers.get(id) === peer) attach(peer, event.channel); else event.channel.close(); };
    peer.pc.onnegotiationneeded = async () => {
      // One fixed channel needs only one initial offer. Device IDs choose the
      // same offerer at both ends, even when requests cross or ICE arrives first.
      // This avoids rolling back the initial SCTP transport during offer glare.
      if (peers.get(id) !== peer || !peer.offerer || peer.makingOffer || peer.pc.localDescription || peer.pc.remoteDescription) return;
      try {
        peer.makingOffer = true;
        await peer.pc.setLocalDescription();
        if (peers.get(id) === peer) signal(peer, peer.pc.localDescription.type, peer.pc.localDescription.toJSON());
      }
      catch (e) { if (peers.get(id) === peer) emit({ kind: 'error', fromDeviceId: id, message: e.message }); }
      finally { peer.makingOffer = false; }
    };
    peer.pc.onconnectionstatechange = () => {
      if (peers.get(id) !== peer) return;
      if (['failed', 'closed'].includes(peer.pc.connectionState)) {
        retire(peer, 'Peer unavailable. TURN may be needed on this network.');
      }
    };
    // Both ends create the same negotiated channel. The higher-ID device asks
    // its partner to offer when it needs a connection; media stays off signaling.
    attach(peer, peer.pc.createDataChannel('scriv-media', { ordered: true, negotiated: true, id: 0 }));
    return peer;
  }
  async function receive(peer, data) {
    if (peers.get(peer.id) !== peer) return;
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
      if (requested.has(key(peer.id, message.hash))) error(peer.id, message.hash, 'That device does not have the requested image.');
    } else if (message.type === 'begin') {
      if (!requested.has(key(peer.id, message.hash)) || peer.receiving || !Number.isSafeInteger(message.bytes) || message.bytes < 1 || message.bytes > maxBytes) throw new Error('Unrequested or oversized image.');
      peer.receiving = { request: requested.get(key(peer.id, message.hash)), hash: message.hash, bytes: message.bytes, received: 0, data: new Uint8Array(message.bytes) };
    } else if (message.type === 'end') {
      const transfer = peer.receiving; peer.receiving = null;
      if (!transfer || transfer.hash !== message.hash || transfer.received !== transfer.bytes) throw new Error('Incomplete image transfer.');
      const actualHash = await digest(transfer.data);
      // Hashing is asynchronous. A disconnect/retry may have replaced this peer
      // and its request while the old checksum was in flight. Never publish the
      // old result into the new session or consume its request deadline.
      if (peers.get(peer.id) !== peer) return;
      const pending = requested.get(key(peer.id, message.hash));
      if (!pending || pending !== transfer.request) throw new Error('Transfer expired.');
      if (actualHash !== message.hash) throw new Error('Image integrity check failed.');
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
    if (peers.get(peer.id) !== peer) return;
    if (!candidate || typeof candidate.candidate !== 'string' || candidate.candidate.length > 4096) throw new Error('Invalid ICE candidate.');
    // Independent HTTP signals can deliver candidates before their SDP. Keep a
    // bounded queue by ICE generation instead of dropping a future generation.
    const ufrag = candidate.usernameFragment;
    const active = peer.pc.remoteDescription?.sdp.match(/^a=ice-ufrag:(.+)$/gm)?.map(line => line.slice(12).trim()) ?? [];
    if (!peer.pc.remoteDescription || (ufrag && active.length && !active.includes(ufrag))) {
      if (peer.candidates.length >= 128) throw new Error('Too many pending ICE candidates.');
      peer.candidates.push(candidate);
      return;
    }
    try { await peer.pc.addIceCandidate(candidate); }
    catch (e) { if (peers.get(peer.id) === peer) throw e; }
  }
  async function applySignal(peer, message) {
    if (peers.get(peer.id) !== peer) return;
    if (message.type === 'asset-request') {
      if (message.payload?.action !== 'connect' || !peer.offerer) throw new Error('Invalid peer connection request.');
      // ensurePeer installed the offerer's negotiation handler. Duplicate
      // connection requests reuse it and cannot start a second offer.
      return;
    }
    if (message.type === 'ice') { await addCandidate(peer, message.payload); return; }
    if (message.type !== 'offer' && message.type !== 'answer') throw new Error('Unsupported peer signal.');
    const description = message.payload;
    if (description?.type !== message.type || typeof description.sdp !== 'string' || description.sdp.length > 65536) throw new Error('Invalid peer description.');
    if ((description.type === 'offer') === peer.offerer) throw new Error('Unexpected peer negotiation role.');
    await peer.pc.setRemoteDescription(description);
    if (peers.get(peer.id) !== peer) return;
    if (description.type === 'offer') {
      await peer.pc.setLocalDescription();
      if (peers.get(peer.id) !== peer) return;
      signal(peer, peer.pc.localDescription.type, peer.pc.localDescription.toJSON());
    }
    for (const candidate of peer.candidates.splice(0)) await addCandidate(peer, candidate);
  }
  globalThis.ScrivPeer = Object.freeze({
    configure(options) {
      if (peers.size) throw new Error('Disconnect transfers before changing identity.');
      const nextID = options?.deviceId, servers = options?.iceServers ?? [], limit = options?.maxBytes ?? HARD_LIMIT;
      if (typeof nextID !== 'string' || !nextID || nextID.length > 128 || !Array.isArray(servers) || !Number.isSafeInteger(limit) || limit < 1) throw new Error('Invalid peer configuration.');
      identity = nextID; iceServers = servers; maxBytes = Math.min(HARD_LIMIT, limit);
    },
    async requestAsset(hash, fromDeviceId) {
      if (!HASH.test(hash)) throw new Error('Invalid image hash.');
      if (requested.has(key(fromDeviceId, hash))) return;
      if (requested.size >= 8) throw new Error('Too many image requests.');
      const pending = { peer: fromDeviceId, hash, sent: false, timer: setTimeout(() => {
        if (requested.get(key(fromDeviceId, hash)) !== pending) return;
        // An unanswered handshake or incomplete stream cannot resume. Retire it
        // so a user retry creates a fresh offer/connect nonce instead of reusing
        // a permanently waiting connection. An ordinary unavailable asset does
        // not take this path and keeps its healthy channel open.
        const peer = peers.get(fromDeviceId);
        if (peer) retire(peer, 'Peer transfer timed out. Try another device or the hosted copy.');
        else error(fromDeviceId, hash, 'Peer transfer timed out.');
      }, 60000) };
      requested.set(key(fromDeviceId, hash), pending);
      try {
        const peer = ensurePeer(fromDeviceId);
        if (!peer.offerer && !peer.pc.remoteDescription && !peer.connectionRequested) {
          peer.connectionRequested = true;
          // A unique ID keeps native signaling deduplication from suppressing a
          // later reconnection between the same two devices.
          signal(peer, 'asset-request', { action: 'connect', requestId: peer.requestId });
        }
        flush(peer);
      }
      catch (e) { error(fromDeviceId, hash, e.message); throw e; }
    },
    async handleSignal(message) {
      if (!['offer', 'answer', 'ice', 'asset-request'].includes(message?.type)) throw new Error('Unsupported peer signal.');
      const connectionRequest = message.type === 'asset-request';
      if (connectionRequest) {
        if (message.payload?.action !== 'connect' || typeof message.payload.requestId !== 'string' || !/^[a-f0-9-]{36}$/.test(message.payload.requestId) || !(identity < message.fromDeviceId)) throw new Error('Invalid peer connection request.');
        const previous = peers.get(message.fromDeviceId);
        // A retry must renew both endpoints. If an offer or answer was lost,
        // the responder can otherwise keep an unanswered offer forever.
        if (previous?.remoteConnectId && previous.remoteConnectId !== message.payload.requestId) retire(previous, 'Peer restarted its connection. Request the image again.');
      }
      const peer = ensurePeer(message.fromDeviceId);
      if (connectionRequest) peer.remoteConnectId = message.payload.requestId;
      // Serialize SDP and candidate application per peer; network arrival is
      // unordered, but no second handler can change a description mid-operation.
      peer.signalQueue = peer.signalQueue.catch(() => {}).then(async () => {
        try { await applySignal(peer, message); }
        catch (e) { if (peers.get(peer.id) === peer) throw e; }
      });
      return peer.signalQueue;
    },
    async provideAsset(peerId, hash, base64) {
      const peer = peers.get(peerId);
      if (!peer?.channel || peer.channel.readyState !== 'open' || !HASH.test(hash)) throw new Error('Peer not connected.');
      peer.sendQueue = peer.sendQueue.catch(() => {}).then(async () => {
        if (peers.get(peerId) !== peer || peer.channel?.readyState !== 'open') throw new Error('Peer not connected.');
        const channel = peer.channel;
        if (base64 === null) { channel.send(JSON.stringify({ type: 'unavailable', hash })); return; }
        if (base64.length > Math.ceil(maxBytes / 3) * 4) throw new Error('Image too large.');
        const bytes = decode(base64);
        if (!bytes.length || bytes.length > maxBytes || await digest(bytes) !== hash) throw new Error('Local image integrity check failed.');
        if (peers.get(peerId) !== peer || channel.readyState !== 'open') throw new Error('Peer not connected.');
        channel.send(JSON.stringify({ type: 'begin', hash, bytes: bytes.length }));
        for (let offset = 0; offset < bytes.length; offset += CHUNK) { await backpressure(channel); channel.send(bytes.subarray(offset, offset + CHUNK)); }
        channel.send(JSON.stringify({ type: 'end', hash }));
      });
      return peer.sendQueue;
    },
    disconnect() {
      for (const pending of requested.values()) clearTimeout(pending.timer);
      requested.clear();
      const closing = Array.from(peers.values());
      peers.clear();
      for (const peer of closing) { peer.receiving = null; peer.channel?.close(); peer.pc.close(); }
    }
  });
  emit({ kind: 'ready' });
})();
