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
    async register(id, homeHash, workHash, persistent = false) {
        const old = this.room(id);
        if (old?.revoked) return { status: 410 };
        if (old) return { status: old.auth.home === homeHash && old.auth.work === workHash ? 200 : 409 };
        if (this.rooms.size >= this.maxRooms) return { status: 503 };
        const box = () => ({ sequence: 0, messages: [], bytes: 0, seen: new Map(), waiters: new Set(), consumer: null });
        this.rooms.set(id, { id, persistent, session: null, resets: new Set(), expires: persistent ? Infinity : this.now() + this.ttl, auth: { home: homeHash, work: workHash }, boxes: { home: box(), work: box() } });
        return { status: 201 };
    }
    async append(id, role, authHash, message, session) {
        const room = this.room(id);
        if (!room || room.revoked) return { status: 410 };
        if (room.auth[role] !== authHash) return { status: 401 };
        if (room.persistent && (!session || room.session !== session)) return { status: 409, session: room.session };
        const box = room.boxes[role === 'home' ? 'work' : 'home'];
        const old = box.seen.get(message.id);
        if (old) return { status: old.hash === message.hash ? 200 : 409, seq: old.seq };
        if (box.messages.length >= 256 || box.bytes + message.body.length > 16 * 1024 * 1024 ||
            this.queuedBytes + message.body.length > 64 * 1024 * 1024 || this.records >= 100000) return { status: 429 };
        const seq = ++box.sequence;
        box.messages.push({ seq, body: message.body }); box.bytes += message.body.length;
        this.queuedBytes += message.body.length; this.records++;
        box.seen.set(message.id, { seq, hash: message.hash });
        for (const waiter of [...box.waiters]) waiter.finish(this.read(room.id, waiter.role, waiter.hash, waiter.after, waiter.consumer, waiter.session));
        return { status: 200, seq };
    }
    read(id, role, authHash, after, consumer, session) {
        const room = this.room(id);
        if (!room || room.revoked) return { status: 410 };
        if (room.auth[role] !== authHash) return { status: 401 };
        if (room.persistent && (!session || room.session !== session)) return { status: 409, session: room.session };
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
    async receive(id, role, authHash, after, consumer, signal, session) {
        const initial = this.read(id, role, authHash, after, consumer, session);
        if (initial.status !== 200 || initial.messages.length) return initial;
        const box = this.room(id)?.boxes[role];
        if (!box) return { status: 410 };
        if (box.waiters.size >= 16) return { status: 429 };
        return new Promise(resolve => {
            const waiter = { role, session, hash: authHash, after, consumer, finish: result => {
                clearTimeout(timer); signal?.removeEventListener('abort', abort);
                box.waiters.delete(waiter); resolve(result);
            } };
            const abort = () => waiter.finish({ status: 499 });
            const timer = setTimeout(() => waiter.finish(this.read(id, role, authHash, after, consumer, session)), this.pollTimeout);
            box.waiters.add(waiter);
            signal?.addEventListener('abort', abort, { once: true });
            if (signal?.aborted) abort();
        });
    }
    async revoke(id, authHash) {
        const room = this.room(id);
        if (!room || room.revoked) return { status: 410 };
        if (room.auth.home !== authHash && !(room.persistent && room.auth.work === authHash)) return { status: 401 };
        if (room.persistent) {
            // Retain only authentication tombstones: a revoked saved code cannot register again.
            for (const box of Object.values(room.boxes)) {
                this.queuedBytes -= box.bytes; this.records -= box.seen.size;
                for (const waiter of [...box.waiters]) waiter.finish({ status: 410 });
                box.messages = []; box.seen.clear(); box.bytes = 0;
            }
            room.revoked = true; room.resets.clear();
        } else { this.remove(room); }
        return { status: 200 };
    }
    async session(id, role, hash, next) {
        const room = this.room(id);
        if (!room || room.revoked) return { status: 410 };
        if (room.auth[role] !== hash) return { status: 401 };
        if (!room.persistent) return { status: 400 };
        if (next && room.session !== next) {
            if (room.resets.has(next)) return { status: 409, session: room.session };
            room.resets.add(next);
            if (room.resets.size > 256) room.resets.delete(room.resets.values().next().value); room.session = next;
            for (const box of Object.values(room.boxes)) {
                this.queuedBytes -= box.bytes; this.records -= box.seen.size;
                for (const waiter of [...box.waiters]) waiter.finish({ status: 409, session: next });
                box.sequence = 0; box.messages = []; box.bytes = 0; box.seen.clear(); box.consumer = null;
            }
        }
        return { status: 200, session: room.session };
    }
    close() { clearInterval(this.sweep); for (const room of [...this.rooms.values()]) this.remove(room); }
}
