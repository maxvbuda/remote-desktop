// ---------- Shared ----------
const $ = (sel) => document.querySelector(sel);
const VIEWS = ['home', 'host-view', 'viewer-view'];

function show(id) {
  for (const v of VIEWS) $('#' + v).hidden = v !== id;
  document.body.dataset.view = id;
}

function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('show');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => t.classList.remove('show'), 2600);
}

function homeError(msg) {
  const e = $('#home-error');
  e.textContent = msg || '';
  e.hidden = !msg;
}

async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);
    toast('Copied');
  } catch {
    toast('Could not copy');
  }
}

const PIN_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
function randomString(len, alphabet) {
  const buf = new Uint32Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (n) => alphabet[n % alphabet.length]).join('');
}
const formatRoom = (r) => r.replace(/(\d{3})(?=\d)/g, '$1 ');
const normalizeRoom = (s) => s.replace(/\D/g, '');
const normalizePin = (s) => s.toUpperCase().replace(/[^A-Z0-9]/g, '');

let iceServers;
async function getIceServers() {
  if (!iceServers) {
    try {
      iceServers = (await (await fetch('/api/ice')).json()).iceServers;
    } catch {
      iceServers = [{ urls: 'stun:stun.cloudflare.com:3478' }];
    }
  }
  return iceServers;
}

// WebSocket to the Room Durable Object. Messages are handled one at a time so
// async WebRTC steps (setRemoteDescription, addIceCandidate) never interleave.
class Signal {
  constructor(room, params) {
    const url = new URL(`/ws/${room}`, location.href);
    url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
    this.onmessage = () => {};
    this.onclose = () => {};
    this.queue = Promise.resolve();
    this.ws = new WebSocket(url);
    this.ws.onmessage = (e) => {
      if (e.data === 'pong') return;
      let msg;
      try { msg = JSON.parse(e.data); } catch { return; }
      this.queue = this.queue.then(() => this.onmessage(msg)).catch(console.error);
    };
    this.ws.onclose = (e) => {
      clearInterval(this.pinger);
      this.onclose(e);
    };
    this.pinger = setInterval(() => {
      if (this.ws.readyState === WebSocket.OPEN) this.ws.send('ping');
    }, 20000);
  }
  send(msg) {
    if (this.ws.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(msg));
  }
  close() {
    this.onclose = () => {};
    this.ws.close();
  }
}

// ---------- Host ----------
const host = { signal: null, stream: null, peers: new Map(), creds: null, active: false, retry: null, agent: false };

function loadCreds(fresh = false) {
  if (!fresh) {
    try {
      const c = JSON.parse(localStorage.getItem('rd-host'));
      if (/^\d{9}$/.test(c?.room) && c?.pin) return c;
    } catch {}
  }
  const c = { room: randomString(1, '123456789') + randomString(8, '0123456789'), pin: randomString(6, PIN_ALPHABET) };
  try { localStorage.setItem('rd-host', JSON.stringify(c)); } catch {}
  return c;
}

async function startHost() {
  homeError();
  if (!navigator.mediaDevices?.getDisplayMedia) {
    return homeError('This browser cannot share its screen. Use Chrome, Edge or Firefox on a desktop computer.');
  }
  let stream;
  try {
    stream = await navigator.mediaDevices.getDisplayMedia({
      video: { displaySurface: 'monitor', frameRate: { ideal: 30, max: 60 } },
      audio: $('#share-audio').checked,
      selfBrowserSurface: 'exclude',
    });
  } catch (err) {
    if (err.name !== 'NotAllowedError') homeError(`Could not start screen sharing: ${err.message}`);
    return;
  }
  host.stream = stream;
  host.active = true;
  host.creds = loadCreds();
  const [track] = stream.getVideoTracks();
  track.contentHint = 'detail';
  track.addEventListener('ended', stopHost);
  const surface = track.getSettings().displaySurface;
  $('#surface-note').hidden = !surface || surface === 'monitor';
  $('#host-preview').srcObject = stream;
  renderCreds();
  renderViewers();
  renderAgent();
  show('host-view');
  connectHost();
}

function connectHost() {
  clearTimeout(host.retry);
  setHostStatus('Connecting…', '');
  host.fatal = null;
  const signal = (host.signal = new Signal(host.creds.room, { role: 'host', pin: host.creds.pin }));
  signal.onmessage = onHostMessage;
  signal.onclose = (e) => {
    for (const id of [...host.peers.keys()]) closePeer(id);
    host.agent = false;
    renderAgent();
    if (!host.active) return;
    if (e.code === 4000) {
      stopHost();
      return homeError('Sharing moved to another tab.');
    }
    if (host.fatal?.code === 'in-use') {
      host.creds = loadCreds(true);
      renderCreds();
      return connectHost();
    }
    setHostStatus('Offline — reconnecting…', 'bad');
    host.retry = setTimeout(connectHost, 2000);
  };
}

async function onHostMessage(msg) {
  switch (msg.type) {
    case 'hello':
      setHostStatus('Online — waiting for connections', 'ok');
      $('#locked-note').hidden = true;
      host.agent = msg.agent;
      renderAgent();
      host.signal.send({ type: 'control', enabled: $('#allow-control').checked });
      break;
    case 'error':
      host.fatal = msg;
      break;
    case 'locked':
      $('#locked-note').hidden = false;
      break;
    case 'viewer-joined':
      host.peers.set(msg.id, { id: msg.id, info: msg.info || {}, state: 'pending', pc: null });
      renderViewers();
      toast('Someone wants to connect');
      break;
    case 'viewer-left':
      closePeer(msg.id);
      break;
    case 'agent':
      host.agent = msg.connected;
      renderAgent();
      break;
    case 'signal': {
      const pc = host.peers.get(msg.from)?.pc;
      if (!pc) return;
      const { sdp, candidate } = msg.data || {};
      if (sdp) {
        await pc.setRemoteDescription(sdp);
        tuneSenders(pc);
      } else if (candidate) {
        await pc.addIceCandidate(candidate).catch(() => {});
      }
      break;
    }
  }
}

async function acceptViewer(id) {
  const peer = host.peers.get(id);
  if (!peer || peer.pc) return;
  peer.state = 'connecting';
  renderViewers();
  host.signal.send({ type: 'accept', to: id });
  const pc = new RTCPeerConnection({ iceServers: await getIceServers() });
  if (host.peers.get(id) !== peer) return pc.close();
  peer.pc = pc;
  for (const track of host.stream.getTracks()) pc.addTrack(track, host.stream);
  pc.onicecandidate = (e) => e.candidate && host.signal.send({ type: 'signal', to: id, data: { candidate: e.candidate } });
  pc.onconnectionstatechange = () => {
    peer.state = pc.connectionState;
    renderViewers();
  };
  await pc.setLocalDescription(await pc.createOffer());
  host.signal.send({ type: 'signal', to: id, data: { sdp: pc.localDescription } });
}

function tuneSenders(pc) {
  for (const sender of pc.getSenders()) {
    if (sender.track?.kind !== 'video') continue;
    const params = sender.getParameters();
    if (!params.encodings?.length) continue;
    params.encodings[0].maxBitrate = 8_000_000;
    params.degradationPreference = 'maintain-resolution';
    sender.setParameters(params).catch(() => {});
  }
}

function kickViewer(id) {
  host.signal?.send({ type: 'kick', to: id });
  closePeer(id);
}

function closePeer(id) {
  host.peers.get(id)?.pc?.close();
  host.peers.delete(id);
  renderViewers();
}

function stopHost() {
  if (!host.active) return;
  host.active = false;
  clearTimeout(host.retry);
  host.signal?.close();
  for (const id of [...host.peers.keys()]) closePeer(id);
  host.stream?.getTracks().forEach((t) => t.stop());
  host.stream = null;
  $('#host-preview').srcObject = null;
  show('home');
}

function setHostStatus(text, cls) {
  $('#host-status').textContent = text;
  $('#host-dot').className = 'dot ' + cls;
}

function renderCreds() {
  const { room, pin } = host.creds;
  $('#host-room').textContent = formatRoom(room);
  $('#host-pin').textContent = pin;
}

function renderAgent() {
  const control = $('#allow-control').checked;
  $('#agent-status').textContent = host.agent
    ? control ? 'Helper connected — viewers can control this computer' : 'Helper connected — control is off'
    : 'Helper app not running';
  $('#agent-dot').className = 'dot ' + (host.agent ? (control ? 'ok' : 'warn') : '');
  if (control && !host.agent) $('#agent-help').open = true;
}

const STATE_LABELS = { pending: 'Wants to connect', connecting: 'Connecting…', new: 'Connecting…', connected: 'Watching', disconnected: 'Interrupted', failed: 'Connection failed', closed: 'Closed' };

function renderViewers() {
  const list = $('#viewer-list');
  list.replaceChildren();
  for (const peer of host.peers.values()) {
    const li = document.createElement('li');
    li.className = peer.state;
    const who = document.createElement('div');
    who.className = 'who';
    const { city, region, country, ip } = peer.info;
    who.textContent = [city, region, country].filter(Boolean).join(', ') || 'Unknown location';
    const small = document.createElement('small');
    small.textContent = `${STATE_LABELS[peer.state] || peer.state}${ip ? ' · ' + ip : ''}`;
    who.append(small);
    li.append(who);
    if (peer.state === 'pending') {
      const accept = document.createElement('button');
      accept.className = 'primary';
      accept.textContent = 'Accept';
      accept.onclick = () => acceptViewer(peer.id);
      const decline = document.createElement('button');
      decline.textContent = 'Decline';
      decline.onclick = () => kickViewer(peer.id);
      li.append(accept, decline);
    } else {
      const kick = document.createElement('button');
      kick.className = 'danger';
      kick.textContent = 'Disconnect';
      kick.onclick = () => kickViewer(peer.id);
      li.append(kick);
    }
    list.append(li);
  }
  $('#viewer-empty').hidden = host.peers.size > 0;
}

$('#start-share').onclick = startHost;
$('#stop-share').onclick = stopHost;
$('#reset-creds').onclick = () => {
  host.creds = loadCreds(true);
  renderCreds();
  host.signal?.close();
  for (const id of [...host.peers.keys()]) closePeer(id);
  connectHost();
  toast('New ID and PIN created');
};
$('#copy-helper-code').onclick = () => copy(helperCode());
$('#copy-link').onclick = () => copy(`${location.origin}/#join=${host.creds.room}`);
$('#allow-control').onchange = (e) => {
  host.signal?.send({ type: 'control', enabled: e.target.checked });
  renderAgent();
};
document.addEventListener('click', (e) => {
  const btn = e.target.closest('[data-copy], [data-copy-code]');
  if (!btn) return;
  if (btn.dataset.copy) copy(host.creds[btn.dataset.copy]);
  else copy(btn.parentElement.querySelector('code').textContent);
});

// ---- Helper app downloads ----
// Built by .github/workflows/helper.yml and attached to the latest GitHub release.
const HELPER_RELEASES = 'https://github.com/maxvbuda/remote-desktop/releases/latest/download';
const HELPER_FILES = {
  windows: 'RemoteDesktopHelper-windows.exe',
  'mac-apple-silicon': 'RemoteDesktopHelper-mac-apple-silicon.zip',
  'mac-intel': 'RemoteDesktopHelper-mac-intel.zip',
  linux: 'RemoteDesktopHelper-linux',
};
const FIRST_RUN = {
  windows: [
    'If Windows says “Windows protected your PC”, click <b>More info</b> → <b>Run anyway</b>.',
  ],
  mac: [
    'Open the downloaded zip, then drag <b>RemoteDesktopHelper</b> into Applications.',
    'The first time, macOS may block it: open System Settings → Privacy &amp; Security and click <b>Open Anyway</b>.',
    'When asked, allow it under <b>Accessibility</b>. The helper window shows a button that takes you there.',
  ],
  linux: [
    'Make it runnable (right-click → Properties → Allow executing), then double-click it. Requires an X11 session.',
  ],
};

// The helper code bundles this site's address, the ID and the PIN.
function helperCode() {
  const site = location.protocol === 'https:' ? location.host : location.origin;
  return `${site}/${host.creds.room}/${host.creds.pin}`;
}

async function detectPlatform() {
  const ua = navigator.userAgent;
  if (/Windows/.test(ua)) return 'windows';
  if (/Mac/.test(ua)) {
    try {
      const { architecture } = await navigator.userAgentData.getHighEntropyValues(['architecture']);
      if (architecture === 'x86') return 'mac-intel';
    } catch {}
    return 'mac-apple-silicon';
  }
  if (/Linux|X11/.test(ua) && !/Android/.test(ua)) return 'linux';
  return null;
}

(async () => {
  for (const a of document.querySelectorAll('[data-helper]')) a.href = `${HELPER_RELEASES}/${HELPER_FILES[a.dataset.helper]}`;
  const platform = await detectPlatform();
  const btn = $('#helper-download');
  if (platform) {
    btn.href = `${HELPER_RELEASES}/${HELPER_FILES[platform]}`;
    btn.textContent = `Download for ${{ windows: 'Windows', 'mac-apple-silicon': 'Mac', 'mac-intel': 'Mac (Intel)', linux: 'Linux' }[platform]}`;
  } else {
    btn.hidden = true;
  }
  const notes = FIRST_RUN[platform?.startsWith('mac') ? 'mac' : platform] || [];
  $('#helper-firstrun').innerHTML = notes.map((n) => `<p>${n}</p>`).join('');
  $('#helper-firstrun').hidden = notes.length === 0;
})();

// ---------- Viewer ----------
const viewer = { signal: null, pc: null, ended: true, message: null, status: { control: false, agent: false }, statsTimer: null };
const stage = $('#stage');
const video = $('#remote-video');

function startViewer(room, pin) {
  homeError();
  Object.assign(viewer, { ended: false, message: null, status: { control: false, agent: false } });
  $('#viewer-title').textContent = formatRoom(room);
  $('#btn-sound').hidden = true;
  renderControlBadge();
  setOverlay('Connecting…');
  show('viewer-view');
  const signal = (viewer.signal = new Signal(room, { role: 'viewer', pin }));
  signal.onmessage = onViewerMessage;
  signal.onclose = () => endViewer(viewer.message || 'Connection to the server was lost.');
}

async function onViewerMessage(msg) {
  switch (msg.type) {
    case 'error': viewer.message = msg.message; break;
    case 'hello': setOverlay('Waiting for the other computer to accept…'); break;
    case 'accepted': setOverlay('Starting the stream…'); break;
    case 'rejected': viewer.message = 'The other computer ended the connection.'; break;
    case 'host-left': viewer.message = 'The other computer stopped sharing.'; break;
    case 'status':
      viewer.status = msg;
      renderControlBadge();
      break;
    case 'signal': {
      const { sdp, candidate } = msg.data || {};
      if (sdp) {
        if (!viewer.pc) viewer.pc = await createViewerPc();
        await viewer.pc.setRemoteDescription(sdp);
        if (sdp.type === 'offer') {
          await viewer.pc.setLocalDescription(await viewer.pc.createAnswer());
          viewer.signal.send({ type: 'signal', data: { sdp: viewer.pc.localDescription } });
        }
      } else if (candidate && viewer.pc) {
        await viewer.pc.addIceCandidate(candidate).catch(() => {});
      }
      break;
    }
  }
}

async function createViewerPc() {
  const pc = new RTCPeerConnection({ iceServers: await getIceServers() });
  pc.onicecandidate = (e) => e.candidate && viewer.signal.send({ type: 'signal', data: { candidate: e.candidate } });
  pc.ontrack = (e) => {
    if (video.srcObject !== e.streams[0]) video.srcObject = e.streams[0];
    if (e.track.kind === 'audio') $('#btn-sound').hidden = false;
  };
  pc.onconnectionstatechange = () => {
    if (pc.connectionState === 'failed') {
      endViewer('Could not establish a direct connection. Setting up a TURN server usually fixes this (see the README).');
    } else if (pc.connectionState === 'disconnected') {
      setOverlay('Connection interrupted, trying to recover…');
    } else if (pc.connectionState === 'connected' && video.readyState >= 2) {
      hideOverlay();
    }
  };
  clearInterval(viewer.statsTimer);
  viewer.statsTimer = setInterval(updateStats, 1000);
  return pc;
}

video.addEventListener('playing', () => {
  hideOverlay();
  stage.focus();
});

let lastBytes = 0, lastTime = 0;
async function updateStats() {
  if (!viewer.pc) return;
  let text = '';
  let rtt;
  (await viewer.pc.getStats()).forEach((s) => {
    if (s.type === 'inbound-rtp' && s.kind === 'video') {
      const mbps = lastTime ? ((s.bytesReceived - lastBytes) * 8) / ((s.timestamp - lastTime) * 1000) : 0;
      lastBytes = s.bytesReceived;
      lastTime = s.timestamp;
      text = `${s.frameWidth || 0}×${s.frameHeight || 0} · ${Math.round(s.framesPerSecond || 0)} fps · ${mbps.toFixed(1)} Mbps`;
    }
    if (s.type === 'candidate-pair' && s.nominated && s.state === 'succeeded') rtt = s.currentRoundTripTime;
  });
  if (rtt != null) text += ` · ${Math.round(rtt * 1000)} ms`;
  $('#viewer-stats').textContent = text;
}

function endViewer(message) {
  if (viewer.ended) return;
  viewer.ended = true;
  releaseAll();
  viewer.signal?.close();
  viewer.pc?.close();
  viewer.pc = null;
  clearInterval(viewer.statsTimer);
  lastBytes = lastTime = 0;
  video.srcObject = null;
  $('#viewer-stats').textContent = '';
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  setOverlay(message, true);
}

function setOverlay(text, done = false) {
  $('#overlay').hidden = false;
  $('#overlay-text').textContent = text;
  $('#overlay-spinner').hidden = done;
  $('#overlay-back').hidden = !done;
}
const hideOverlay = () => ($('#overlay').hidden = true);

function canControl() {
  return Boolean(viewer.pc && viewer.status.control && viewer.status.agent && !viewer.ended);
}

function renderControlBadge() {
  const b = $('#control-badge');
  const { control, agent } = viewer.status;
  b.textContent = control && agent ? 'Control on' : control ? 'Control allowed — agent offline' : 'View only';
  b.className = 'badge ' + (control && agent ? 'ok' : control ? 'warn' : '');
  stage.classList.toggle('controlling', control && agent);
  if (!(control && agent)) releaseAll();
}

// ---- Input capture ----
const sendInput = (ev) => viewer.signal?.send({ type: 'input', ...ev });
const round = (n) => Math.round(n * 10000) / 10000;

// Map a pointer position to 0..1 coordinates on the video picture,
// accounting for letterboxing from object-fit: contain.
function videoPoint(e, clamp = false) {
  const vw = video.videoWidth, vh = video.videoHeight;
  if (!vw || !vh) return null;
  const r = video.getBoundingClientRect();
  const scale = Math.min(r.width / vw, r.height / vh);
  const w = vw * scale, h = vh * scale;
  let x = (e.clientX - (r.left + (r.width - w) / 2)) / w;
  let y = (e.clientY - (r.top + (r.height - h) / 2)) / h;
  if (clamp) {
    x = Math.min(1, Math.max(0, x));
    y = Math.min(1, Math.max(0, y));
  } else if (x < 0 || x > 1 || y < 0 || y > 1) {
    return null;
  }
  return { x: round(x), y: round(y) };
}

const buttonsDown = new Set();
const keysDown = new Map();
const BUTTON_BITS = { 0: 1, 1: 4, 2: 2 };
let pendingMove = null;

function flushMove() {
  if (pendingMove) sendInput({ e: 'move', ...pendingMove });
  pendingMove = null;
}

function onPointerButton(e) {
  if (!(e.button in BUTTON_BITS)) return;
  const down = (e.buttons & BUTTON_BITS[e.button]) !== 0;
  if (down && !buttonsDown.has(e.button)) {
    const p = videoPoint(e);
    if (!p) return;
    stage.setPointerCapture?.(e.pointerId);
    buttonsDown.add(e.button);
    pendingMove = null;
    sendInput({ e: 'down', b: e.button, ...p });
  } else if (!down && buttonsDown.has(e.button)) {
    buttonsDown.delete(e.button);
    flushMove();
    sendInput({ e: 'up', b: e.button, ...videoPoint(e, true) });
  }
}

stage.addEventListener('pointerdown', (e) => {
  stage.focus();
  if (!canControl()) return;
  e.preventDefault();
  onPointerButton(e);
});
stage.addEventListener('pointerup', (e) => canControl() && onPointerButton(e));
stage.addEventListener('pointermove', (e) => {
  if (!canControl()) return;
  if (e.button >= 0) return onPointerButton(e); // chorded button change
  const p = videoPoint(e, buttonsDown.size > 0);
  if (!p) return;
  if (!pendingMove) requestAnimationFrame(flushMove);
  pendingMove = p;
});
stage.addEventListener('contextmenu', (e) => canControl() && e.preventDefault());

const WHEEL_STEP = 100;
const wheelAcc = { x: 0, y: 0 };
stage.addEventListener('wheel', (e) => {
  if (!canControl()) return;
  e.preventDefault();
  const k = e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? 800 : 1;
  wheelAcc.x += e.deltaX * k;
  wheelAcc.y += e.deltaY * k;
  const dx = Math.trunc(wheelAcc.x / WHEEL_STEP), dy = Math.trunc(wheelAcc.y / WHEEL_STEP);
  if (dx || dy) {
    wheelAcc.x -= dx * WHEEL_STEP;
    wheelAcc.y -= dy * WHEEL_STEP;
    sendInput({ e: 'wheel', dx, dy });
  }
}, { passive: false });

const keyFields = (e) => ({ key: e.key, code: e.code, ctrl: e.ctrlKey, alt: e.altKey, meta: e.metaKey, shift: e.shiftKey });
const MODIFIERS = new Set(['Shift', 'Control', 'Alt', 'AltGraph', 'Meta', 'OS', 'CapsLock']);

stage.addEventListener('keydown', (e) => {
  if (!canControl() || e.isComposing) return;
  e.preventDefault();
  keysDown.set(e.code || e.key, keyFields(e));
  sendInput({ e: 'kd', ...keyFields(e) });
});
stage.addEventListener('keyup', (e) => {
  if (!canControl()) return;
  e.preventDefault();
  keysDown.delete(e.code || e.key);
  sendInput({ e: 'ku', ...keyFields(e) });
  // macOS browsers swallow keyup for keys pressed while ⌘ is held; release them.
  if (e.key === 'Meta') {
    for (const [id, k] of keysDown) {
      if (MODIFIERS.has(k.key)) continue;
      keysDown.delete(id);
      sendInput({ e: 'ku', ...k });
    }
  }
});
stage.addEventListener('blur', releaseAll);

function releaseAll() {
  if (buttonsDown.size || keysDown.size) sendInput({ e: 'reset' });
  buttonsDown.clear();
  keysDown.clear();
}

// ---- Toolbar ----
$('#btn-disconnect').onclick = () => {
  endViewer('Disconnected.');
  show('home');
};
$('#overlay-back').onclick = () => show('home');
$('#btn-fullscreen').onclick = async () => {
  if (document.fullscreenElement) return document.exitFullscreen();
  await $('#viewer-view').requestFullscreen().catch(() => {});
  navigator.keyboard?.lock?.().catch(() => {});
  stage.focus();
};
$('#btn-scale').onclick = (e) => {
  const actual = stage.classList.toggle('actual');
  e.target.textContent = actual ? 'Fit to window' : 'Actual size';
};
$('#btn-sound').onclick = (e) => {
  video.muted = !video.muted;
  e.target.textContent = video.muted ? 'Unmute' : 'Mute';
};
$('#btn-text').onclick = () => {
  $('#text-pop').hidden = !$('#text-pop').hidden;
  if (!$('#text-pop').hidden) $('#text-input').focus();
};
$('#text-cancel').onclick = () => {
  $('#text-pop').hidden = true;
  stage.focus();
};
$('#text-pop').onsubmit = (e) => {
  e.preventDefault();
  const text = $('#text-input').value;
  if (!text) return;
  if (!canControl()) return toast('Remote control is not available right now');
  sendInput({ e: 'text', text: text.slice(0, 5000) });
  $('#text-input').value = '';
  $('#text-pop').hidden = true;
  stage.focus();
};

// ---------- Home ----------
$('#connect-form').onsubmit = (e) => {
  e.preventDefault();
  const room = normalizeRoom($('#join-room').value);
  const pin = normalizePin($('#join-pin').value);
  if (room.length !== 9) return homeError('The computer ID has 9 digits.');
  if (pin.length < 4) return homeError('Enter the PIN shown on the other computer.');
  startViewer(room, pin);
};

const invite = location.hash.match(/join=(\d{9})/);
if (invite) {
  $('#join-room').value = formatRoom(invite[1]);
  $('#join-pin').focus();
  history.replaceState(null, '', location.pathname);
}
