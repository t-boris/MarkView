import { Readable } from 'node:stream';
import { EventEmitter } from 'node:events';
import { createHash, timingSafeEqual } from 'node:crypto';
import { createRelay } from './server.mjs';

/** Adapts the same tested relay to Cloudflare's Request/Response runtime.
 * Each invitation is routed to one Durable Object, so concurrent HTTP polls share a mailbox.
 * No separate database, domain, VPS, client software or provider API key is needed.
 */
export class RelayRoom {
    constructor() { this.relay = createRelay({ maxRooms: 1 }); }

    async fetch(request) {
        const url = new URL(request.url);
        const req = request.body ? Readable.fromWeb(request.body) : Readable.from([]);
        Object.assign(req, { method: request.method, url: url.pathname + url.search,
            headers: Object.fromEntries(request.headers) });
        const res = new EventEmitter();
        res.destroyed = false; res.writableEnded = false;
        return new Promise((resolve, reject) => {
            let status = 200, headers = {};
            res.writeHead = (value, fields) => { status = value; headers = fields; };
            res.end = data => {
                res.writableEnded = true;
                resolve(new Response(data, { status, headers }));
                res.emit('close');
                if (status === 410 || (request.method === 'DELETE' && status === 200)) this.relay.close();
            };
            request.signal.addEventListener('abort', () => {
                res.destroyed = true; res.emit('close');
                resolve(new Response(null, { status: 499 }));
            }, { once: true });
            Promise.resolve(this.relay.handler(req, res)).catch(reject);
        });
    }
}

export default {
    async fetch(request, env) {
        const url = new URL(request.url);
        const respond = (status, value) => Response.json(value, { status, headers: { 'Cache-Control': 'no-store' } });
        if (request.headers.has('Origin')) return respond(403, {});
        if (url.pathname === '/healthz' && request.method === 'GET') return respond(200, { protocol: 1 });
        let room, forwarded = request;
        if (url.pathname === '/v1/rooms' && request.method === 'POST') {
            // Provisioning is private: arbitrary visitors cannot allocate long-lived room objects.
            if (!env.REGISTRATION_TOKEN) return respond(503, { error: 'Relay access key is not configured.' });
            const supplied = request.headers.get('X-Registration-Token') ?? '';
            const hash = value => createHash('sha256').update(value).digest();
            if (!timingSafeEqual(hash(supplied), hash(env.REGISTRATION_TOKEN))) return respond(403, {});
            // Registration is small. Bound its stream before parsing/routing it to an object.
            if (!request.body) return respond(400, {});
            const reader = request.body.getReader();
            const chunks = []; let length = 0;
            while (true) {
                const { value, done } = await reader.read();
                if (done) break;
                length += value.length;
                if (length > 4096) { await reader.cancel(); return respond(413, {}); }
                chunks.push(value);
            }
            const bytes = new Uint8Array(length); let offset = 0;
            for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
            const body = new TextDecoder().decode(bytes);
            try { room = JSON.parse(body).room; } catch { return respond(400, {}); }
            forwarded = new Request(request.url, { method: 'POST', headers: request.headers, body });
        } else { room = /^\/v1\/rooms\/([0-9a-f-]+)(?:\/(?:home|work))?$/.exec(url.pathname)?.[1]; }
        if (typeof room !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(room)) return respond(404, {});
        const id = env.ROOMS.idFromName(room);
        return env.ROOMS.get(id).fetch(forwarded);
    },
};
