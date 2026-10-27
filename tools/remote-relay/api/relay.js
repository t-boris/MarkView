import { createRelay } from '../server.mjs';
import { RedisRelayStore } from '../redis-store.mjs';
import { RedisHTTP } from '../redis-http.mjs';

export function createVercelRelay({ environment = () => process.env,
    createStore = ({ url, token }) => new RedisRelayStore(new RedisHTTP({ url, token })) } = {}) {
    let service;
    return async function relay(req, res) {
        const env = environment();
        const url = env.UPSTASH_REDIS_REST_URL ?? env.KV_REST_API_URL;
        const token = env.UPSTASH_REDIS_REST_TOKEN ?? env.KV_REST_API_TOKEN;
        const registrationToken = env.REGISTRATION_TOKEN;
        if (!url || !token || !registrationToken) {
            res.writeHead(503, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
            res.end(JSON.stringify({ error: 'Relay storage and access key must be configured.' }));
            return;
        }
        // No in-memory fallback: every function instance uses the same atomic Redis store.
        try { service ??= createRelay({ registrationToken, store: createStore({ url, token }) }); }
        catch {
            res.writeHead(503, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
            res.end(JSON.stringify({ error: 'Relay storage configuration is invalid.' }));
            return;
        }
        const route = new URL(req.url, 'http://relay.local');
        const original = route.searchParams.get('relayPath') ?? req.query?.relayPath;
        route.searchParams.delete('relayPath');
        for (const name of ['after', 'consumer']) {
            if (!route.searchParams.has(name) && typeof req.query?.[name] === 'string') route.searchParams.set(name, req.query[name]);
        }
        if (typeof original === 'string') req.url = original + route.search;
        return service.handler(req, res);
    };
}

export default createVercelRelay();
