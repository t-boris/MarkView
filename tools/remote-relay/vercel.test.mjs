import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { EventEmitter } from 'node:events';
import { randomBytes, randomUUID } from 'node:crypto';
import { createVercelRelay } from './api/relay.js';
import { MemoryRelayStore } from './memory-store.mjs';

function request(handler, { method = 'GET', url, body, token = '', query, key = '' }) {
    const req = Readable.from([]);
    Object.assign(req, { method, url, query, body, headers: { authorization: `Bearer ${token}`, 'x-registration-token': key } });
    const res = new EventEmitter();
    res.destroyed = false; res.writableEnded = false;
    return new Promise((resolve, reject) => {
        res.writeHead = status => { res.status = status; };
        res.end = data => { res.writableEnded = true; resolve({ status: res.status, body: JSON.parse(data) }); res.emit('close'); };
        Promise.resolve(handler(req, res)).catch(reject);
    });
}

test('Vercel requires shared storage and a private provisioning key', async () => {
    let fallback = false;
    const handler = createVercelRelay({ environment: () => ({}), createStore() { fallback = true; } });
    assert.equal((await request(handler, { url: '/healthz' })).status, 503);
    assert.equal(fallback, false, 'An unconfigured serverless function must never create an independent queue.');
});

test('Vercel URL rewrites and parsed request bodies use the shared protocol boundary', async () => {
    const store = new MemoryRelayStore({ pollTimeout: 5 });
    const env = { KV_REST_API_URL: 'https://redis.test', KV_REST_API_TOKEN: 'test', REGISTRATION_TOKEN: 'test-access-key' };
    const first = createVercelRelay({ environment: () => env, createStore: () => store });
    const second = createVercelRelay({ environment: () => env, createStore: () => store });
    const room = randomUUID(), home = randomBytes(32).toString('base64url'), work = randomBytes(32).toString('base64url');
    try {
        assert.equal((await request(first, { url: '/api/relay?relayPath=/healthz' })).status, 200);
        const registered = await request(first, { method: 'POST', url: '/api/relay', query: { relayPath: '/v1/rooms' },
            token: home, key: env.REGISTRATION_TOKEN, body: { room, homeToken: home, workToken: work } });
        assert.equal(registered.status, 201);
        const body = randomBytes(64).toString('base64');
        assert.equal((await request(first, { method: 'POST', url: `/api/relay?relayPath=/v1/rooms/${room}/home`, token: home, body: { id: randomUUID(), body } })).status, 200);
        const received = await request(second, { url: '/api/relay', token: work, query: { relayPath: `/v1/rooms/${room}/work`, after: '0', consumer: randomUUID() } });
        assert.deepEqual(received.body.messages, [{ seq: 1, body }]);
    } finally { store.close(); }
});
