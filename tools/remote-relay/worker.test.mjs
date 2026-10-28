import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import worker, { RelayRoom } from './worker.mjs';

test('Worker routes both endpoints to one invitation object using the real relay handler', async () => {
    const objects = new Map();
    const env = { REGISTRATION_TOKEN: randomBytes(32).toString('base64url'), ROOMS: { idFromName: name => name, get: id => {
        if (!objects.has(id)) objects.set(id, new RelayRoom());
        return objects.get(id);
    } } };
    const room = randomUUID(), home = randomBytes(32).toString('base64url'), work = randomBytes(32).toString('base64url');
    const request = (path, method, token, body) => worker.fetch(new Request('https://relay.test' + path, {
        method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-Registration-Token': env.REGISTRATION_TOKEN },
        body: body === undefined ? undefined : JSON.stringify(body),
    }), env);
    try {
        assert.equal((await request('/healthz', 'GET', '')).status, 200);
        assert.equal((await request('/v1/rooms', 'POST', home, { room, homeToken: home, workToken: work })).status, 201);
        const body = randomBytes(64).toString('base64');
        assert.equal((await request(`/v1/rooms/${room}/home`, 'POST', home, { id: randomUUID(), body })).status, 200);
        const received = await request(`/v1/rooms/${room}/work?after=0&consumer=${randomUUID()}`, 'GET', work);
        assert.deepEqual((await received.json()).messages, [{ seq: 1, body }]);
        assert.equal(objects.size, 1);
        assert.equal((await request(`/v1/rooms/${room}`, 'DELETE', home)).status, 200);
        assert.equal((await request(`/v1/rooms/${room}/home?after=0&consumer=${randomUUID()}`, 'GET', home)).status, 410);
    } finally { for (const object of objects.values()) object.relay.close(); }
});

test('Worker validates registration before allocating an invitation object', async () => {
    const env = { REGISTRATION_TOKEN: 'test-key', ROOMS: { idFromName() { throw new Error('must not allocate'); } } };
    const headers = { 'X-Registration-Token': env.REGISTRATION_TOKEN };
    assert.equal((await worker.fetch(new Request('https://relay.test/v1/rooms', { method: 'POST', body: '{}' }), env)).status, 403);
    assert.equal((await worker.fetch(new Request('https://relay.test/v1/rooms', { method: 'POST', headers, body: 'bad JSON' }), env)).status, 400);
    assert.equal((await worker.fetch(new Request('https://relay.test/v1/rooms', { method: 'POST', headers, body: 'x'.repeat(5000) }), env)).status, 413);
    assert.equal((await worker.fetch(new Request('https://relay.test/v1/rooms/not-a-uuid/work'), env)).status, 404);
});

test('Worker saved connection session endpoints retain revocation tombstones', async () => {
    const object = new RelayRoom(), key = randomBytes(32).toString('base64url');
    const env = { REGISTRATION_TOKEN: key, ROOMS: { idFromName: name => name, get: () => object } };
    const room = randomUUID(), home = randomBytes(32).toString('base64url'), work = randomBytes(32).toString('base64url');
    const request = (path, method, token, body) => worker.fetch(new Request('https://relay.test' + path, {
        method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-Registration-Token': key },
        body: body === undefined ? undefined : JSON.stringify(body),
    }), env);
    const registration = { room, homeToken: home, workToken: work, persistent: true };
    try {
        assert.equal((await (await request('/healthz', 'GET', home)).json()).persistentConnections, true);
        assert.equal((await request('/v1/rooms', 'POST', home, registration)).status, 201);
        const epoch = randomUUID();
        assert.equal((await (await request(`/v1/rooms/${room}/session/home`, 'POST', home, { session: epoch })).json()).session, epoch);
        assert.equal((await request(`/v1/rooms/${room}`, 'DELETE', work)).status, 200);
        assert.equal((await request(`/v1/rooms/${room}/session/home`, 'GET', home)).status, 410);
        assert.equal((await request('/v1/rooms', 'POST', home, registration)).status, 410);
    } finally { object.relay.close(); }
});
