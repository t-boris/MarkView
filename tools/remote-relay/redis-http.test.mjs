import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RedisHTTP } from './redis-http.mjs';

test('Redis HTTP sends server credentials in headers and rejects redirects or store errors', async () => {
    let seen;
    const client = new RedisHTTP({ url: 'https://redis.test', token: 'private-test-token', fetch: async (url, options) => {
        seen = { url, options };
        return Response.json({ result: [200, 1] });
    } });
    assert.deepEqual(await client.command(['EVAL', 'return {200,1}', '0']), [200, 1]);
    assert.equal(seen.url, 'https://redis.test');
    assert.equal(seen.options.headers.Authorization, 'Bearer private-test-token');
    assert.equal(seen.options.redirect, 'error');
    assert.deepEqual(JSON.parse(seen.options.body), ['EVAL', 'return {200,1}', '0']);
    assert.throws(() => new RedisHTTP({ url: 'http://redis.test', token: 'test' }));
    const failed = new RedisHTTP({ url: 'https://redis.test', token: 'secret', fetch: async () => Response.json({ error: 'private upstream diagnostics' }) });
    await assert.rejects(failed.command(['PING']), error => error.status === 503 && !error.message.includes('private'));
});

test('Redis subscription waits for acknowledgement and handles events split across HTTP chunks', async () => {
    let stream, aborted = false;
    const client = new RedisHTTP({ url: 'https://redis.test', token: 'test', fetch: async (url, options) => {
        assert.equal(url, 'https://redis.test/subscribe/room%3Anotify');
        options.signal.addEventListener('abort', () => { aborted = true; stream.close(); }, { once: true });
        return new Response(new ReadableStream({ start(controller) { stream = controller; } }), { headers: { 'Content-Type': 'text/event-stream' } });
    } });
    const encoder = new TextEncoder();
    const pending = client.subscribe('room:notify', 1000);
    stream.enqueue(encoder.encode('data: sub'));
    stream.enqueue(encoder.encode('scribe,room:notify,1\n\n'));
    const subscription = await pending;
    stream.enqueue(encoder.encode('data: message,room:not'));
    stream.enqueue(encoder.encode('ify,changed\n\n'));
    await subscription.changed;
    subscription.close();
    assert.equal(aborted, true);
});

test('An unavailable Redis subscription fails closed without leaking credentials', async () => {
    const client = new RedisHTTP({ url: 'https://redis.test', token: 'private-test-token', fetch: async () => new Response('', { status: 401 }) });
    await assert.rejects(client.subscribe('room', 100), error => error.status === 503 && !error.message.includes('private-test-token'));
});
