/** Single-process implementation of the relay store contract. Protocol validation is shared
 * by Node, Workers and Vercel; durable deployments inject a shared atomic store.
 */
export class MemoryRelayStore {
    constructor({ ttl = 8 * 60 * 60 * 1000, pollTimeout = 20000, maxRooms = 1000, now = Date.now } = {}) {
        Object.assign(this, { ttl, pollTimeout, maxRooms, now });
        this.rooms = new Map(); this.queuedBytes = 0; this.records = 0;
        this.sweep = setInterval(() => {
            for (const room of this.rooms.values()) if (this.now() >= room.expires) this.remove(room);
        }, 30000);
        this.sweep.unref?.();
    }
    room(id) {
        const room = this.rooms.get(id);
        if (room && this.now() >= room.expires) { this.remove(room); return undefined; }
        return room;
    }
    remove(room) {
        this.rooms.delete(room.id);
        for (const box of Object.values(room.boxes)) {
            this.queuedBytes -= box.bytes; this.records -= box.seen.size;
            for (const waiter of [...box.waiters]) waiter.finish({ status: 410 });
        }
    }
    async register(id, homeHash, workHash) {
        const old = this.room(id);
        if (old) return { status: old.auth.home === homeHash && old.auth.work === workHash ? 200 : 409 };
        if (this.rooms.size >= this.maxRooms) return { status: 503 };
        const box = () => ({ sequence: 0, messages: [], bytes: 0, seen: new Map(), waiters: new Set(), consumer: null });
        this.rooms.set(id, { id, expires: this.now() + this.ttl, auth: { home: homeHash, work: workHash }, boxes: { home: box(), work: box() } });
        return { status: 201 };
    }
    async append(id, role, authHash, message) {
        const room = this.room(id);
        if (!room) return { status: 410 };
        if (room.auth[role] !== authHash) return { status: 401 };
        const box = room.boxes[role === 'home' ? 'work' : 'home'];
        const old = box.seen.get(message.id);
        if (old) return { status: old.hash === message.hash ? 200 : 409, seq: old.seq };
        if (box.messages.length >= 256 || box.bytes + message.body.length > 16 * 1024 * 1024 ||
            this.queuedBytes + message.body.length > 64 * 1024 * 1024 || this.records >= 100000) return { status: 429 };
        const seq = ++box.sequence;
        box.messages.push({ seq, body: message.body }); box.bytes += message.body.length;
        this.queuedBytes += message.body.length; this.records++;
        box.seen.set(message.id, { seq, hash: message.hash });
        for (const waiter of [...box.waiters]) waiter.finish(this.read(room.id, waiter.role, waiter.hash, waiter.after, waiter.consumer));
        return { status: 200, seq };
    }
    read(id, role, authHash, after, consumer) {
        const room = this.room(id);
        if (!room) return { status: 410 };
        if (room.auth[role] !== authHash) return { status: 401 };
        const box = room.boxes[role];
        if (after > box.sequence) return { status: 400 };
        if (box.consumer && box.consumer !== consumer) return { status: 409 };
        box.consumer = consumer;
        while (box.messages.length && box.messages[0].seq <= after) {
            const size = box.messages.shift().body.length;
            box.bytes -= size; this.queuedBytes -= size;
        }
        const messages = []; let bytes = 0;
        for (const message of box.messages) {
            if (messages.length >= 8 || bytes + message.body.length > 3 * 1024 * 1024) break;
            messages.push(message); bytes += message.body.length;
        }
        return { status: 200, messages };
    }
    async receive(id, role, authHash, after, consumer, signal) {
        const initial = this.read(id, role, authHash, after, consumer);
        if (initial.status !== 200 || initial.messages.length) return initial;
        const box = this.room(id)?.boxes[role];
        if (!box) return { status: 410 };
        if (box.waiters.size >= 16) return { status: 429 };
        return new Promise(resolve => {
            const waiter = { role, hash: authHash, after, consumer, finish: result => {
                clearTimeout(timer); signal?.removeEventListener('abort', abort);
                box.waiters.delete(waiter); resolve(result);
            } };
            const abort = () => waiter.finish({ status: 499 });
            const timer = setTimeout(() => waiter.finish(this.read(id, role, authHash, after, consumer)), this.pollTimeout);
            box.waiters.add(waiter);
            signal?.addEventListener('abort', abort, { once: true });
            if (signal?.aborted) abort();
        });
    }
    async revoke(id, authHash) {
        const room = this.room(id);
        if (!room) return { status: 410 };
        if (room.auth.home !== authHash) return { status: 401 };
        this.remove(room); return { status: 200 };
    }
    close() { clearInterval(this.sweep); for (const room of [...this.rooms.values()]) this.remove(room); }
}
