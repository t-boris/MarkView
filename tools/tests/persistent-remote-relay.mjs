// Loopback-only failure fixture. The production store survives the injected HTTP outage.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { createRelay } from '../remote-relay/server.mjs';
const root = fs.realpathSync(process.argv[2] ?? '');
if (path.dirname(root) !== fs.realpathSync('/tmp') || !path.basename(root).startsWith('mvpersist-test-')) {
    throw new Error('Refusing a non-test relay directory');
}
const relay = createRelay({ pollTimeout: 100 });
let offlineUntil = 0;
const server = http.createServer((req, res) => {
    if (req.url === '/test/outage' && req.method === 'POST') {
        offlineUntil = Date.now() + 12000; res.writeHead(200); res.end('{}'); return;
    }
    if (Date.now() < offlineUntil) { res.writeHead(503); res.end('{}'); return; }
    relay.handler(req, res);
});
server.listen(0, '127.0.0.1', () => {
    fs.writeFileSync(path.join(root, 'relay.port'), String(server.address().port), { mode: 0o600, flag: 'wx' });
});
process.on('SIGTERM', () => { relay.close(); server.close(() => process.exit(0)); });
