// Loopback-only failure fixture. The production store survives the injected HTTP outage.
import http from 'node:http';
import { createRelay } from '../remote-relay/server.mjs';
const relay = createRelay({ pollTimeout: 100 });
let offlineUntil = 0;
const server = http.createServer((req, res) => {
    if (req.url === '/test/outage' && req.method === 'POST') {
        offlineUntil = Date.now() + 12000; res.writeHead(200); res.end('{}'); return;
    }
    if (Date.now() < offlineUntil) { res.writeHead(503); res.end('{}'); return; }
    relay.handler(req, res);
});
server.listen(16393, '127.0.0.1');
process.on('SIGTERM', () => { relay.close(); server.close(() => process.exit(0)); });
