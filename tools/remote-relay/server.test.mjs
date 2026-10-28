import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { EventEmitter } from 'node:events';
import { randomBytes, randomUUID } from 'node:crypto';
import { createRelay } from './server.mjs';

// Exercise the real HTTP handler in memory as well as on a socket in the integration test.
// This keeps protocol checks runnable in environments that forbid binding network listeners.
function request(relay, method, url, token, value, headers = {}) {
    const req = Readable.from(value === undefined ? [] : [Buffer.from(JSON.stringify(value))]);
    Object.assign(req, { method, url, headers: { authorization: `Bearer ${token}`, ...headers } });
    const res = new EventEmitter();
    res.destroyed = false; res.writableEnded = false;
    return new Promise((resolve, reject) => {
        res.writeHead = status => { res.status = status; };
        res.end = data => { res.writableEnded = true; resolve({ status: res.status, body: JSON.parse(data) }); res.emit('close'); };
        Promise.resolve(relay.handler(req, res)).catch(reject);
    });
}
async function fixture(options = {}) {
    const relay = createRelay({ pollTimeout: 5, ...options });
    const room = randomUUID(), home = randomBytes(32).toString('base64url'), work = randomBytes(32).toString('base64url');
    const create = await request(relay, 'POST', '/v1/rooms', home, { room, homeToken: home, workToken: work });
    assert.equal(create.status, 201);
    return { relay, room, home, work, path: `/v1/rooms/${room}` };
}
const payload = () => ({ id: randomUUID(), body: randomBytes(64).toString('base64') });

test('roles authenticate independently and messages are acknowledged only by their receiver', async () => {
    const f = await fixture();
    try {
        const message = payload();
        assert.equal((await request(f.relay, 'POST', f.path + '/home', f.work, message)).status, 401);
        assert.equal((await request(f.relay, 'POST', f.path + '/home', f.home, message)).status, 200);
        const consumer = randomUUID();
        let result = await request(f.relay, 'GET', f.path + `/work?after=0&consumer=${consumer}`, f.work);
        assert.deepEqual(result.body.messages, [{ seq: 1, body: message.body }]);
        result = await request(f.relay, 'GET', f.path + `/work?after=0&consumer=${consumer}`, f.work);
        assert.equal(result.body.messages.length, 1, 'an unacknowledged response must be replayed');
        result = await request(f.relay, 'GET', f.path + `/work?after=1&consumer=${consumer}`, f.work);
        assert.deepEqual(result.body.messages, []);
    } finally { f.relay.close(); }
});

test('ambiguous send retries are deduplicated and cannot replace the original request', async () => {
    const f = await fixture();
    try {
        const message = payload();
        const first = await request(f.relay, 'POST', f.path + '/work', f.work, message);
        const retry = await request(f.relay, 'POST', f.path + '/work', f.work, message);
        assert.equal(first.body.seq, retry.body.seq);
        assert.equal((await request(f.relay, 'POST', f.path + '/work', f.work, { ...message, body: payload().body })).status, 409);
        const result = await request(f.relay, 'GET', f.path + `/home?after=0&consumer=${randomUUID()}`, f.home);
        assert.equal(result.body.messages.length, 1);
    } finally { f.relay.close(); }
});

test('one invitation binds one consumer; invalid cursors cannot delete queued work', async () => {
    const f = await fixture();
    try {
        await request(f.relay, 'POST', f.path + '/home', f.home, payload());
        assert.equal((await request(f.relay, 'GET', f.path + `/work?after=9999&consumer=${randomUUID()}`, f.work)).status, 400);
        assert.equal((await request(f.relay, 'GET', f.path + `/work?after=0&consumer=${randomUUID()}`, f.work)).status, 200);
        assert.equal((await request(f.relay, 'GET', f.path + `/work?after=0&consumer=${randomUUID()}`, f.work)).status, 409);
    } finally { f.relay.close(); }
});

test('revocation wakes long polls and removes both mailboxes', async () => {
    const f = await fixture({ pollTimeout: 10000 });
    const pending = request(f.relay, 'GET', f.path + `/work?after=0&consumer=${randomUUID()}`, f.work);
    assert.equal((await request(f.relay, 'DELETE', f.path, f.work)).status, 401);
    assert.equal((await request(f.relay, 'DELETE', f.path, f.home)).status, 200);
    assert.equal((await pending).status, 410);
    assert.equal((await request(f.relay, 'POST', f.path + '/work', f.work, payload())).status, 410);
    f.relay.close();
});

test('expired invitations and cross-origin requests are rejected', async () => {
    let now = 100;
    const f = await fixture({ ttl: 10, now: () => now });
    try {
        assert.equal((await request(f.relay, 'GET', '/healthz', '', undefined, { origin: 'https://other.example' })).status, 403);
        now = 111;
        assert.equal((await request(f.relay, 'POST', f.path + '/home', f.home, payload())).status, 410);
    } finally { f.relay.close(); }
});

test('queues apply backpressure without discarding or acknowledging commands', async () => {
    const f = await fixture();
    try {
        for (let i = 0; i < 256; i++) assert.equal((await request(f.relay, 'POST', f.path + '/home', f.home, payload())).status, 200);
        assert.equal((await request(f.relay, 'POST', f.path + '/home', f.home, payload())).status, 429);
        const first = await request(f.relay, 'GET', f.path + `/work?after=0&consumer=${randomUUID()}`, f.work);
        assert.equal(first.body.messages[0].seq, 1);
        assert.equal(first.body.messages.length, 8);
    } finally { f.relay.close(); }
});

test('Encrypted frames and response batches stay below serverless payload limits', async () => {
    const f = await fixture();
    try {
        const body = 'A'.repeat(2 * 1024 * 1024), consumer = randomUUID();
        for (let i = 0; i < 2; i++) assert.equal((await request(f.relay, 'POST', f.path + '/home', f.home, { id: randomUUID(), body })).status, 200);
        const first = await request(f.relay, 'GET', f.path + `/work?after=0&consumer=${consumer}`, f.work);
        assert.equal(first.body.messages.length, 1);
        assert.ok(Buffer.byteLength(JSON.stringify(first.body)) < 4.5 * 1000 * 1000);
        const second = await request(f.relay, 'GET', f.path + `/work?after=1&consumer=${consumer}`, f.work);
        assert.equal(second.body.messages[0].seq, 2);
        assert.equal((await request(f.relay, 'POST', f.path + '/home', f.home, { id: randomUUID(), body: body + 'A' })).status, 400);
    } finally { f.relay.close(); }
});

test('saved pairings survive eight hours, isolate new epochs and cannot be resurrected after either peer revokes', async () => {
    let now = 0;
    const relay = createRelay({ ttl: 10, now: () => now, pollTimeout: 5 });
    const room = randomUUID(), home = randomBytes(32).toString('base64url'), work = randomBytes(32).toString('base64url');
    const path = `/v1/rooms/${room}`;
    const registration = { room, homeToken: home, workToken: work, persistent: true };
    try {
        assert.equal((await request(relay, 'GET', '/healthz', home)).body.persistentConnections, true);
        assert.equal((await request(relay, 'POST', '/v1/rooms', home, registration)).status, 201);
        now = 9 * 60 * 60 * 1000;
        const epoch1 = randomUUID(), epoch2 = randomUUID();
        assert.equal((await request(relay, 'POST', path + '/session/work', home, { session: epoch1 })).status, 401);
        assert.equal((await request(relay, 'POST', path + '/session/home', home, { session: epoch1 })).body.session, epoch1);
        const header1 = { 'x-markview-session': epoch1 }, header2 = { 'x-markview-session': epoch2 };
        const old = payload();
        assert.equal((await request(relay, 'POST', path + '/home', home, old, header1)).status, 200);
        assert.equal((await request(relay, 'POST', path + '/session/work', work, { session: epoch2 })).status, 200);
        assert.equal((await request(relay, 'POST', path + '/work', work, payload(), header1)).status, 409);
        assert.equal((await request(relay, 'GET', path + `/work?after=0&consumer=${randomUUID()}`, work, undefined, header2)).body.messages.length, 0);
        const next = payload();
        assert.equal((await request(relay, 'POST', path + '/home', home, next, header2)).body.seq, 1);
        assert.equal((await request(relay, 'POST', path + '/session/work', work, { session: epoch2 })).status, 200);
        assert.equal((await request(relay, 'POST', path + '/session/home', home, { session: epoch1 })).status, 409);
        assert.equal((await request(relay, 'GET', path + '/session/home', home)).body.session, epoch2);
        assert.equal((await request(relay, 'DELETE', path, work)).status, 200);
        assert.equal((await request(relay, 'POST', '/v1/rooms', home, registration)).status, 410);
        assert.equal((await request(relay, 'GET', path + '/session/home', home)).status, 410);
    } finally { relay.close(); }
});
