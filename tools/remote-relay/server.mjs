import http from 'node:http';
import https from 'node:https';
import { createHash, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const digest = value => createHash('sha256').update(value).digest();
const equal = (value, hash) => typeof value === 'string' && timingSafeEqual(digest(value), hash);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const token = /^[A-Za-z0-9_-]{43}$/;
const maxBody = 6 * 1024 * 1024;

/** Encrypted, acknowledged mailboxes. No provider credentials, file paths or plaintext are stored.
 * Deploy behind HTTPS or supply TLS_CERT/TLS_KEY. The only work-laptop client is MarkView itself.
 */
export function createRelay({ ttl = 8 * 60 * 60 * 1000, pollTimeout = 20000, maxRooms = 1000,
    now = Date.now, registrationToken = process.env.REGISTRATION_TOKEN } = {}) {
    const rooms = new Map();
    const reply = (res, status, body = {}) => {
        if (res.destroyed || res.writableEnded) return;
        res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store',
            'X-Content-Type-Options': 'nosniff' });
        res.end(JSON.stringify(body));
    };
    const remove = room => {
        for (const box of Object.values(room.boxes)) {
            for (const waiter of box.waiters) { clearTimeout(waiter.timer); reply(waiter.res, 410); }
        }
        rooms.delete(room.id);
    };
    const sweep = setInterval(() => {
        for (const room of rooms.values()) if (now() - room.created >= ttl) remove(room);
    }, 30000);
    sweep.unref?.();
    const body = async req => {
        let bytes = 0;
        const chunks = [];
        for await (const chunk of req) {
            bytes += chunk.length;
            if (bytes > maxBody) throw Object.assign(new Error(), { status: 413 });
            chunks.push(chunk);
        }
        try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
        catch { throw Object.assign(new Error(), { status: 400 }); }
    };
    const box = () => ({ sequence: 0, messages: [], bytes: 0, seen: new Map(), waiters: new Set(), consumer: null });
    const deliver = (room, role, res, after) => {
        const target = room.boxes[role];
        const messages = [];
        let bytes = 0;
        for (const message of target.messages) {
            if (message.seq <= after) continue;
            if (messages.length >= 8 || bytes + message.body.length > 8 * 1024 * 1024) break;
            messages.push(message); bytes += message.body.length;
        }
        reply(res, 200, { messages: messages.map(({ seq, body }) => ({ seq, body })) });
    };
    const wake = (room, role) => {
        const target = room.boxes[role];
        for (const waiter of target.waiters) {
            clearTimeout(waiter.timer); target.waiters.delete(waiter);
            deliver(room, role, waiter.res, waiter.after);
        }
    };
    const handler = async (req, res) => {
        try {
            if (req.headers.origin) return reply(res, 403);
            const url = new URL(req.url, 'http://relay.local');
            if (url.pathname === '/healthz' && req.method === 'GET') return reply(res, 200, { protocol: 1 });
            const bearer = /^Bearer (.+)$/.exec(req.headers.authorization ?? '')?.[1];
            if (url.pathname === '/v1/rooms' && req.method === 'POST') {
                if (registrationToken && !equal(req.headers['x-registration-token'], digest(registrationToken))) return reply(res, 403);
                const data = await body(req);
                if (!uuid.test(data.room) || !token.test(data.homeToken) || !token.test(data.workToken) || data.homeToken === data.workToken)
                    return reply(res, 400);
                if (!equal(bearer, digest(data.homeToken))) return reply(res, 401);
                const existing = rooms.get(data.room);
                if (existing) return reply(res, equal(bearer, existing.auth.home) ? 200 : 409);
                if (rooms.size >= maxRooms) return reply(res, 503);
                rooms.set(data.room, { id: data.room, created: now(),
                    auth: { home: digest(data.homeToken), work: digest(data.workToken) },
                    boxes: { home: box(), work: box() } });
                return reply(res, 201);
            }
            const match = /^\/v1\/rooms\/([0-9a-f-]+)(?:\/(home|work))?$/.exec(url.pathname);
            if (!match) return reply(res, 404);
            const room = rooms.get(match[1]);
            if (!room) return reply(res, 410);
            if (now() - room.created >= ttl) { remove(room); return reply(res, 410); }
            if (!match[2] && req.method === 'DELETE') {
                if (!equal(bearer, room.auth.home)) return reply(res, 401);
                remove(room); return reply(res, 200);
            }
            const role = match[2];
            if (!role || !equal(bearer, room.auth[role])) return reply(res, 401);
            const target = room.boxes[role];
            if (req.method === 'GET') {
                const afterText = url.searchParams.get('after');
                const after = Number(afterText);
                const consumer = url.searchParams.get('consumer');
                if (!afterText || !Number.isSafeInteger(after) || after < 0 || after > target.sequence || !uuid.test(consumer ?? '')) return reply(res, 400);
                if (target.consumer && target.consumer !== consumer) return reply(res, 409);
                target.consumer = consumer;
                if (target.waiters.size) return reply(res, 409);
                while (target.messages.length && target.messages[0].seq <= after) target.bytes -= target.messages.shift().body.length;
                if (target.messages.length) return deliver(room, role, res, after);
                const waiter = { res, after, timer: null };
                waiter.timer = setTimeout(() => { target.waiters.delete(waiter); deliver(room, role, res, after); }, pollTimeout);
                target.waiters.add(waiter);
                res.on('close', () => { clearTimeout(waiter.timer); target.waiters.delete(waiter); });
                return;
            }
            if (req.method === 'POST') {
                const data = await body(req);
                if (!uuid.test(data.id) || typeof data.body !== 'string' || data.body.length < 32 || data.body.length > maxBody || !/^[A-Za-z0-9+/=]+$/.test(data.body)) return reply(res, 400);
                const destination = role === 'home' ? 'work' : 'home';
                const mailbox = room.boxes[destination];
                const old = mailbox.seen.get(data.id);
                if (old) return reply(res, equal(data.body, old.hash) ? 200 : 409, { seq: old.seq });
                if (mailbox.messages.length >= 256 || mailbox.bytes + data.body.length > 16 * 1024 * 1024) return reply(res, 429);
                const seq = ++mailbox.sequence;
                mailbox.messages.push({ seq, body: data.body }); mailbox.bytes += data.body.length;
                mailbox.seen.set(data.id, { seq, hash: digest(data.body) });
                // Never evict deduplication records during a room's lifetime: dropping them could
                // replay a command after an ambiguous network failure. Rotate the connection instead.
                if (mailbox.seen.size > 100000) { remove(room); return reply(res, 410); }
                wake(room, destination);
                return reply(res, 200, { seq });
            }
            reply(res, 405);
        } catch (error) { reply(res, error.status ?? 500); }
    };
    return { handler, close() { clearInterval(sweep); for (const room of rooms.values()) remove(room); } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    const relay = createRelay();
    const options = process.env.TLS_CERT && process.env.TLS_KEY
        ? { cert: readFileSync(process.env.TLS_CERT), key: readFileSync(process.env.TLS_KEY) } : null;
    const server = options ? https.createServer(options, relay.handler) : http.createServer(relay.handler);
    server.requestTimeout = 30000;
    server.headersTimeout = 15000;
    const host = process.env.HOST ?? '127.0.0.1';
    const port = Number(process.env.PORT ?? 8787);
    server.listen(port, host, () => process.stderr.write(`MarkView relay listening on ${host}:${port}\n`));
    const shutdown = () => { relay.close(); server.close(() => process.exit(0)); };
    process.on('SIGTERM', shutdown); process.on('SIGINT', shutdown);
}
