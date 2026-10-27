import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { RedisRelayStore } from './redis-store.mjs';

// A dedicated Redis service is required. Never fall back to or flush a developer's default DB.
// CI supplies REDIS_TEST_PORT and runs the production Lua scripts against real Redis.
const port = process.env.REDIS_TEST_PORT;
const hash = value => createHash('sha256').update(value).digest('hex');
const cliArgs = ['-h', '127.0.0.1', '-p', String(port)];
const connection = {
    command(command) {
        return new Promise((resolve, reject) => {
            const child = spawn('redis-cli', [...cliArgs, '--json', ...(command.length === 1 ? command : ['-x', ...command.slice(0, -1)])]);
            let output = '', errors = '';
            child.stdout.on('data', data => { output += data; }); child.stderr.on('data', data => { errors += data; });
            child.on('error', reject);
            child.on('close', code => {
                try {
                    if (code || output.startsWith('error:')) throw new Error(errors || output);
                    resolve(JSON.parse(output));
                } catch (error) { reject(error); }
            });
            child.stdin.end(command.length === 1 ? undefined : command.at(-1));
        });
    },
    async subscribe(channel, timeout, signal) {
        const child = spawn('redis-cli', [...cliArgs, '--raw', 'SUBSCRIBE', channel]);
        let readyResolve, readyReject, changedResolve, buffer = '', rows = [];
        const ready = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
        const changed = new Promise(resolve => { changedResolve = resolve; });
        const close = () => { clearTimeout(timer); signal?.removeEventListener('abort', close); child.kill(); changedResolve(); };
        const timer = setTimeout(close, timeout);
        signal?.addEventListener('abort', close, { once: true });
        child.stdout.on('data', data => {
            buffer += data;
            let end;
            while ((end = buffer.indexOf('\n')) !== -1) {
                rows.push(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
                if (rows.length === 3) {
                    if (rows[0] === 'subscribe') readyResolve();
                    if (rows[0] === 'message') changedResolve();
                    rows = [];
                }
            }
        });
        child.on('error', readyReject);
        child.on('close', () => { readyReject(new Error('Redis subscription closed')); changedResolve(); });
        try { await ready; return { changed, close }; }
        catch (error) { close(); throw error; }
    },
};

test('Redis atomically shares authentication, queue order, deduplication and acknowledgements across function instances', { skip: !port }, async () => {
    const first = new RedisRelayStore(connection, { ttl: 60000, pollTimeout: 80 });
    const second = new RedisRelayStore(connection, { ttl: 60000, pollTimeout: 80 });
    const room = randomUUID(), home = hash('home-' + room), work = hash('work-' + room), consumer = randomUUID();
    try {
        await first.health();
        assert.equal((await first.register(room, home, work)).status, 201);
        assert.equal((await second.register(room, home, work)).status, 200);
        assert.equal((await second.register(room, hash('other'), work)).status, 409);
        const body = Buffer.from('encrypted test frame, not a work file').toString('base64');
        const message = { id: randomUUID(), body, hash: hash(body) };
        const results = await Promise.all(Array.from({ length: 12 }, (_, n) => (n % 2 ? first : second).append(room, 'home', home, message)));
        assert.ok(results.every(result => result.status === 200 && result.seq === 1));
        assert.equal((await second.append(room, 'home', work, message)).status, 401);
        assert.equal((await second.append(room, 'home', home, { ...message, hash: hash('different') })).status, 409);
        assert.equal((await first.read(room, 'work', work, 999, consumer)).status, 400);
        assert.deepEqual((await second.read(room, 'work', work, 0, consumer)).messages, [{ seq: 1, body }]);
        assert.equal((await first.read(room, 'work', work, 0, randomUUID())).status, 409);
        assert.deepEqual((await first.read(room, 'work', work, 1, consumer)).messages, []);
        assert.equal((await second.append(room, 'home', home, message)).seq, 1, 'Acknowledging a frame must not delete its deduplication record.');
        assert.deepEqual((await second.read(room, 'work', work, 1, consumer)).messages, []);
        const waiting = second.receive(room, 'work', work, 1, consumer);
        const next = { id: randomUUID(), body, hash: hash(body) };
        assert.equal((await first.append(room, 'home', home, next)).seq, 2);
        assert.deepEqual((await waiting).messages, [{ seq: 2, body }], 'A publish racing subscription setup must not be lost.');
        assert.equal((await second.revoke(room, work)).status, 401);
        assert.equal((await first.revoke(room, home)).status, 200);
        assert.equal((await second.read(room, 'work', work, 2, consumer)).status, 410);
    } finally { await first.revoke(room, home); }
});

test('Redis room expiry removes credentials and queued ciphertext', { skip: !port }, async () => {
    const store = new RedisRelayStore(connection, { ttl: 50 });
    const room = randomUUID();
    assert.equal((await store.register(room, hash('home'), hash('work'))).status, 201);
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal((await store.read(room, 'home', hash('home'), 0, randomUUID())).status, 410);
});
