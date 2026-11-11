import { DurableObject } from 'cloudflare:workers';

// Computer IDs are 9 digits; each one maps to its own Room Durable Object.
const ROOM_PATH = /^\/ws\/(\d{9})$/;
const MAX_PIN_FAILURES = 10;
const OPEN = 1;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === '/api/ice') {
      return Response.json(
        { iceServers: await getIceServers(env) },
        { headers: { 'Cache-Control': 'no-store' } },
      );
    }

    const match = url.pathname.match(ROOM_PATH);
    if (match) {
      if (request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
        return new Response('Expected a WebSocket upgrade', { status: 426 });
      }
      const room = env.ROOMS.get(env.ROOMS.idFromName(match[1]));
      return room.fetch(request);
    }

    return env.ASSETS.fetch(request);
  },
};

// STUN always works for simple networks. To relay through strict NATs and
// firewalls, either set TURN_SERVERS to a JSON array of ICE servers from any
// TURN provider, or set TURN_KEY_ID / TURN_KEY_API_TOKEN for Cloudflare Realtime.
async function getIceServers(env) {
  const fallback = [{ urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302'] }];
  if (env.TURN_SERVERS) {
    try {
      return [...fallback, ...[].concat(JSON.parse(env.TURN_SERVERS))];
    } catch (err) {
      console.error('TURN_SERVERS is not valid JSON', err);
    }
  }
  if (!env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) return fallback;

  try {
    const res = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ ttl: 86400 }),
      },
    );
    if (!res.ok) throw new Error(`TURN credentials request failed: ${res.status}`);
    const { iceServers } = await res.json();
    // Browsers time out on port 53 URLs, so drop them.
    return [].concat(iceServers).map((server) => ({
      ...server,
      urls: [].concat(server.urls).filter((u) => !/:53(\?|$)/.test(u)),
    }));
  } catch (err) {
    console.error(err);
    return fallback;
  }
}

/**
 * One Room per computer ID. It relays WebRTC signaling between the host (the
 * shared Mac) and viewers, and only lets viewers the host accepted through.
 * Video and input normally travel peer-to-peer over WebRTC. When the devices
 * can't reach each other, the viewer asks for relay mode and the host streams
 * H.264 through this object as binary messages instead.
 *
 * Sockets are tagged by role ("host" | "viewer") and carry their state in
 * WebSocket attachments, so the object can hibernate between messages.
 */
export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  async fetch(request) {
    const url = new URL(request.url);
    const role = url.searchParams.get('role');
    const pin = (url.searchParams.get('pin') || '').toUpperCase();
    const [client, server] = Object.values(new WebSocketPair());

    // Denials are delivered as a message over a short-lived socket so clients
    // can show the reason.
    const denial = await this.admit(role, pin);
    if (denial) {
      server.accept();
      server.send(JSON.stringify({ type: 'error', ...denial }));
      server.close(4003, denial.code);
      return new Response(null, { status: 101, webSocket: client });
    }

    const id = crypto.randomUUID().slice(0, 8);
    const attachment = { role, id };

    if (role === 'host') {
      attachment.pin = pin;
      attachment.control = false;
      // Same ID + PIN from another window: the newer session takes over.
      for (const old of this.sockets('host')) {
        this.send(old, { type: 'replaced' });
        this.drop(old, 4000, 'Replaced by a newer session');
      }
      for (const viewer of this.sockets('viewer')) {
        this.send(viewer, { type: 'host-left' });
        this.drop(viewer, 4002, 'Host reconnected');
      }
      await this.ctx.storage.delete('failures');
    } else if (role === 'viewer') {
      attachment.approved = false;
      attachment.info = {
        ip: request.headers.get('CF-Connecting-IP') || '',
        city: request.cf?.city || '',
        region: request.cf?.region || '',
        country: request.cf?.country || '',
      };
    }

    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment(attachment);

    this.send(server, { type: 'hello', id });
    if (role === 'viewer') {
      this.send(this.host().ws, { type: 'viewer-joined', id, info: attachment.info });
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  async admit(role, pin) {
    if (!['host', 'viewer'].includes(role)) {
      return { code: 'bad-request', message: 'Unknown role.' };
    }
    if (!/^[A-Z0-9]{4,32}$/.test(pin)) {
      return { code: 'bad-pin', message: 'Invalid PIN.' };
    }

    const host = this.host();
    if (role === 'host') {
      return host && host.att.pin !== pin
        ? { code: 'in-use', message: 'This computer ID is already in use.' }
        : null;
    }
    if (!host) {
      return {
        code: 'offline',
        message: 'That computer is not online. Check the ID and make sure it is sharing.',
      };
    }

    const failures = (await this.ctx.storage.get('failures')) || 0;
    if (failures >= MAX_PIN_FAILURES) {
      return {
        code: 'locked',
        message: 'Too many wrong PINs. Ask the other person to click “New ID & PIN”.',
      };
    }
    if (pin !== host.att.pin) {
      await this.ctx.storage.put('failures', failures + 1);
      if (failures + 1 >= MAX_PIN_FAILURES) this.send(host.ws, { type: 'locked' });
      return { code: 'bad-pin', message: 'Wrong PIN.' };
    }
    return null;
  }

  async webSocketMessage(ws, raw) {
    const att = ws.deserializeAttachment();
    // Binary messages are relayed video from the host (used when the devices
    // can't connect directly): forward them to viewers that asked for relay.
    if (typeof raw !== 'string') {
      if (att.role !== 'host') return;
      for (const viewer of this.sockets('viewer')) {
        const v = viewer.deserializeAttachment();
        if (v.approved && v.relay) this.send(viewer, raw);
      }
      return;
    }
    if (raw.length > 64 * 1024) return;
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    if (att.role === 'host') this.fromHost(ws, att, msg);
    else if (att.role === 'viewer') this.fromViewer(ws, att, msg);
  }

  fromHost(ws, att, msg) {
    const viewer = this.viewer(msg.to);
    switch (msg.type) {
      case 'signal':
        if (viewer?.att.approved) {
          this.send(viewer.ws, { type: 'signal', from: att.id, data: msg.data });
        }
        break;
      case 'accept':
        if (!viewer) break;
        viewer.att.approved = true;
        viewer.ws.serializeAttachment(viewer.att);
        this.send(viewer.ws, { type: 'accepted' });
        this.send(viewer.ws, this.status(att));
        break;
      case 'kick':
        if (!viewer) break;
        this.send(viewer.ws, { type: 'rejected' });
        this.drop(viewer.ws, 4001, 'Disconnected by host');
        break;
      case 'control':
        att.control = msg.enabled === true;
        ws.serializeAttachment(att);
        this.broadcastStatus();
        break;
    }
  }

  fromViewer(ws, att, msg) {
    if (!att.approved) return;
    const host = this.host();
    if (!host) return;
    switch (msg.type) {
      case 'signal':
        this.send(host.ws, { type: 'signal', from: att.id, data: msg.data });
        break;
      case 'relay-request':
        att.relay = true;
        ws.serializeAttachment(att);
        this.send(host.ws, { type: 'relay-request', from: att.id });
        break;
      case 'input':
        // Relay mode only; direct connections send input over WebRTC.
        if (att.relay && host.att.control) this.send(host.ws, { type: 'input', from: att.id, ev: msg.ev });
        break;
    }
  }

  async webSocketClose(ws) {
    this.cleanup(ws);
  }

  async webSocketError(ws) {
    this.cleanup(ws);
  }

  cleanup(ws) {
    const att = ws.deserializeAttachment();
    this.drop(ws, 1000, 'Closed');
    if (!att) return;

    if (att.role === 'host') {
      // A replaced host closing must not tear down its successor's room.
      if (this.sockets('host').length > 0) return;
      for (const other of this.sockets('viewer')) {
        this.send(other, { type: 'host-left' });
        this.drop(other, 4002, 'Host disconnected');
      }
      return;
    }

    const host = this.host();
    if (att.role === 'viewer' && host) this.send(host.ws, { type: 'viewer-left', id: att.id });
  }

  sockets(role) {
    return this.ctx.getWebSockets(role).filter((ws) => ws.readyState === OPEN);
  }

  host() {
    const ws = this.sockets('host')[0];
    return ws ? { ws, att: ws.deserializeAttachment() } : null;
  }

  viewer(id) {
    for (const ws of this.sockets('viewer')) {
      const att = ws.deserializeAttachment();
      if (att.id === id) return { ws, att };
    }
    return null;
  }

  status(hostAtt) {
    return { type: 'status', control: Boolean(hostAtt?.control) };
  }

  broadcastStatus() {
    const status = this.status(this.host()?.att);
    for (const ws of this.sockets('viewer')) {
      if (ws.deserializeAttachment().approved) this.send(ws, status);
    }
  }

  send(ws, msg) {
    try {
      const raw = typeof msg === 'string' || msg instanceof ArrayBuffer ? msg : JSON.stringify(msg);
      ws.send(raw);
    } catch {}
  }

  drop(ws, code, reason) {
    try {
      ws.close(code, reason);
    } catch {}
  }
}
