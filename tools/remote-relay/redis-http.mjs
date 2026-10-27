const unavailable = () => Object.assign(new Error('The relay store is unavailable.'), { status: 503 });

/** Upstash-compatible HTTPS Redis client. Credentials stay in server-side environment variables.
 * Pub/Sub wakes long polls without continuous Redis polling, WebSockets or a permanent process.
 */
export class RedisHTTP {
    constructor({ url, token, fetch: request = globalThis.fetch }) {
        const endpoint = new URL(url);
        if (endpoint.protocol !== 'https:' || endpoint.username || endpoint.password || endpoint.search || endpoint.hash || !token) throw unavailable();
        this.url = url.replace(/\/$/, ''); this.token = token; this.request = request;
    }
    async command(command) {
        try {
            const response = await this.request(this.url, { method: 'POST',
                headers: { Authorization: 'Bearer ' + this.token, 'Content-Type': 'application/json' },
                body: JSON.stringify(command), signal: AbortSignal.timeout(10000), redirect: 'error' });
            if (!response.ok) throw unavailable();
            const value = await response.json();
            if (value.error || value.result === undefined) throw unavailable();
            return value.result;
        } catch { throw unavailable(); }
    }
    async subscribe(channel, timeout, signal) {
        const controller = new AbortController();
        const abort = () => controller.abort();
        signal?.addEventListener('abort', abort, { once: true });
        const timer = setTimeout(abort, timeout);
        let readyResolve, readyReject, changedResolve, ready = false;
        const readyPromise = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
        const changed = new Promise(resolve => { changedResolve = resolve; });
        const close = () => { clearTimeout(timer); clearTimeout(readyTimer); signal?.removeEventListener('abort', abort); controller.abort(); };
        const readyTimer = setTimeout(() => { readyReject(unavailable()); abort(); }, 5000);
        if (signal?.aborted) abort();
        const listen = async () => {
            const response = await this.request(this.url + '/subscribe/' + encodeURIComponent(channel), {
                method: 'POST', headers: { Authorization: 'Bearer ' + this.token, Accept: 'text/event-stream' },
                signal: controller.signal, redirect: 'error' });
            if (!response.ok || !response.body) throw unavailable();
            const reader = response.body.getReader(), decoder = new TextDecoder();
            let buffer = '';
            try {
                while (true) {
                    const { value, done } = await reader.read();
                    if (done) break;
                    buffer += decoder.decode(value, { stream: true });
                    if (buffer.length > 65536) throw unavailable();
                    let end;
                    while ((end = buffer.indexOf('\n')) !== -1) {
                        const line = buffer.slice(0, end).trim(); buffer = buffer.slice(end + 1);
                        if (!line.startsWith('data:')) continue;
                        const event = line.slice(5).trim();
                        if (event.startsWith('subscribe,')) { ready = true; clearTimeout(readyTimer); readyResolve(); }
                        else if (event.startsWith('message,')) changedResolve();
                    }
                }
            } finally { await reader.cancel().catch(() => {}); }
            if (!ready) throw unavailable();
        };
        listen().catch(() => { if (!ready) readyReject(unavailable()); }).finally(() => { changedResolve(); close(); });
        try { await readyPromise; return { changed, close }; }
        catch { close(); throw unavailable(); }
    }
}
