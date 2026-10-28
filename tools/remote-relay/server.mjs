import http from 'node:http';
import https from 'node:https';
import { createHash, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { MemoryRelayStore } from './memory-store.mjs';

const digest = value => createHash('sha256').update(value).digest('hex');
const equal = (value, expected) => typeof value === 'string' && timingSafeEqual(Buffer.from(digest(value), 'hex'), Buffer.from(digest(expected), 'hex'));
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const token = /^[A-Za-z0-9_-]{43}$/;
const maxBody = 2 * 1024 * 1024 + 4096;

/** Shared HTTP boundary for standalone Node, Workers and Vercel. The store owns atomic
 * authentication, acknowledgement and deduplication. A failed shared store never falls
 * back to an independent in-memory queue.
 */
export function createRelay(options = {}) {
    const store = options.store ?? new MemoryRelayStore(options);
    const registrationToken = options.registrationToken ?? process.env.REGISTRATION_TOKEN;
    const reply = (res, status, body = {}) => {
        if (res.destroyed || res.writableEnded) return;
        res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
        res.end(JSON.stringify(body));
    };
    const body = async req => {
        if (req.body !== undefined) {
            const text = typeof req.body === 'string' ? req.body : Buffer.isBuffer(req.body) ? req.body.toString('utf8') : JSON.stringify(req.body);
            if (Buffer.byteLength(text) > maxBody) throw Object.assign(new Error(), { status: 413 });
            try { return JSON.parse(text); } catch { throw Object.assign(new Error(), { status: 400 }); }
        }
        let size = 0; const chunks = [];
        for await (const chunk of req) {
            size += chunk.length;
            if (size > maxBody) throw Object.assign(new Error(), { status: 413 });
            chunks.push(chunk);
        }
        try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw Object.assign(new Error(), { status: 400 }); }
    };
    const send = (res, result) => {
        const { status, ...data } = result;
        reply(res, status, data);
    };
    const handler = async (req, res) => {
        try {
            if (req.headers.origin) return reply(res, 403);
            const url = new URL(req.url, 'http://relay.local');
            if (url.pathname === '/healthz' && req.method === 'GET') {
                await store.health?.();
                return reply(res, 200, { protocol: 2, persistentConnections: true });
            }
            const bearer = /^Bearer (.+)$/.exec(req.headers.authorization ?? '')?.[1];
            if (!bearer) return reply(res, 401);
            const authHash = digest(bearer);
            if (url.pathname === '/v1/rooms' && req.method === 'POST') {
                if (registrationToken && !equal(req.headers['x-registration-token'], registrationToken)) return reply(res, 403);
                const data = await body(req);
                if (!data || !uuid.test(data.room) || !token.test(data.homeToken) || !token.test(data.workToken) || data.homeToken === data.workToken) return reply(res, 400);
                if (!equal(bearer, data.homeToken)) return reply(res, 401);
                return send(res, await store.register(data.room, digest(data.homeToken), digest(data.workToken), data.persistent === true));
            }
            const sessionMatch = /^\/v1\/rooms\/([0-9a-f-]+)\/session\/(home|work)$/.exec(url.pathname);
            if (sessionMatch && uuid.test(sessionMatch[1]) && ['GET', 'POST'].includes(req.method)) {
                const next = req.method === 'POST' ? (await body(req)).session : undefined;
                if (req.method === 'POST' && !uuid.test(next ?? '')) return reply(res, 400);
                return send(res, await store.session(sessionMatch[1], sessionMatch[2], authHash, next));
            }
            const match = /^\/v1\/rooms\/([0-9a-f-]+)(?:\/(home|work))?$/.exec(url.pathname);
            if (!match || !uuid.test(match[1])) return reply(res, 404);
            const [, room, role] = match;
            if (!role && req.method === 'DELETE') return send(res, await store.revoke(room, authHash));
            if (!role) return reply(res, 405);
            if (req.method === 'GET') {
                const raw = url.searchParams.get('after'), after = Number(raw), consumer = url.searchParams.get('consumer');
                if (!raw || !Number.isSafeInteger(after) || after < 0 || !uuid.test(consumer ?? '')) return reply(res, 400);
                const cancellation = new AbortController(), abort = () => cancellation.abort();
                res.on('close', abort);
                try { return send(res, await store.receive(room, role, authHash, after, consumer, cancellation.signal, req.headers['x-markview-session'])); }
                finally { res.removeListener('close', abort); }
            }
            if (req.method === 'POST') {
                const data = await body(req);
                if (!data || !uuid.test(data.id) || typeof data.body !== 'string' || data.body.length < 32 || data.body.length > 2 * 1024 * 1024 || !/^[A-Za-z0-9+/=]+$/.test(data.body)) return reply(res, 400);
                return send(res, await store.append(room, role, authHash, { id: data.id, body: data.body, hash: digest(data.body) }, req.headers['x-markview-session']));
            }
            reply(res, 405);
        } catch (error) { reply(res, error.status ?? 500); }
    };
    return { handler, close() { store.close(); } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    const relay = createRelay();
    const options = process.env.TLS_CERT && process.env.TLS_KEY ? { cert: readFileSync(process.env.TLS_CERT), key: readFileSync(process.env.TLS_KEY) } : null;
    const server = options ? https.createServer(options, relay.handler) : http.createServer(relay.handler);
    server.requestTimeout = 30000; server.headersTimeout = 15000;
    const host = process.env.HOST ?? '127.0.0.1', port = Number(process.env.PORT ?? 8787);
    server.listen(port, host, () => process.stderr.write('MarkView relay listening on ' + host + ':' + port + '\n'));
    const shutdown = () => { relay.close(); server.close(() => process.exit(0)); };
    process.on('SIGTERM', shutdown); process.on('SIGINT', shutdown);
}
