// All room keys, bodies, authentication hashes and delivery IDs share one expiring Redis hash.
// Every mutation authenticates inside EVAL, so revocation cannot race an append or acknowledgement.
const auth = `
if redis.call('EXISTS', KEYS[1]) == 0 then return {410} end
if redis.call('HGET', KEYS[1], 'auth:' .. ARGV[1]) ~= ARGV[2] then return {401} end
`;
const register = `
local ttl = tonumber(ARGV[3])
if not ttl or ttl <= 0 or ttl > 86400000 or ttl ~= math.floor(ttl) then return {400} end
if redis.call('EXISTS', KEYS[1]) == 1 then
  if redis.call('HGET', KEYS[1], 'auth:home') == ARGV[1] and redis.call('HGET', KEYS[1], 'auth:work') == ARGV[2] then return {200} end
  return {409}
end
redis.call('HSET', KEYS[1], 'auth:home', ARGV[1], 'auth:work', ARGV[2])
redis.call('PEXPIRE', KEYS[1], ttl)
return {201}
`;
const append = auth + `
local role = ARGV[1] == 'home' and 'work' or 'home'
local previous = redis.call('HGET', KEYS[1], 'id:' .. role .. ':' .. ARGV[3])
if previous then
  local divider = string.find(previous, ':')
  if string.sub(previous, divider + 1) ~= ARGV[4] then return {409} end
  return {200, tonumber(string.sub(previous, 1, divider - 1))}
end
local seq = tonumber(redis.call('HGET', KEYS[1], 'seq:' .. role) or '0')
local ack = tonumber(redis.call('HGET', KEYS[1], 'ack:' .. role) or '0')
local bytes = tonumber(redis.call('HGET', KEYS[1], 'bytes:' .. role) or '0')
local seen = tonumber(redis.call('HGET', KEYS[1], 'seen') or '0')
local size = string.len(ARGV[5])
if seq - ack >= 256 or bytes + size > 16777216 or seen >= 100000 then return {429} end
seq = redis.call('HINCRBY', KEYS[1], 'seq:' .. role, 1)
redis.call('HINCRBY', KEYS[1], 'bytes:' .. role, size)
redis.call('HINCRBY', KEYS[1], 'seen', 1)
redis.call('HSET', KEYS[1], 'body:' .. role .. ':' .. seq, ARGV[5], 'id:' .. role .. ':' .. ARGV[3], seq .. ':' .. ARGV[4])
redis.call('PUBLISH', KEYS[1] .. ':notify:' .. role, tostring(seq))
return {200, seq}
`;
const read = auth + `
local role = ARGV[1]
local after = tonumber(ARGV[3])
local seq = tonumber(redis.call('HGET', KEYS[1], 'seq:' .. role) or '0')
if after > seq then return {400} end
local consumer = redis.call('HGET', KEYS[1], 'consumer:' .. role)
if consumer and consumer ~= ARGV[4] then return {409} end
redis.call('HSET', KEYS[1], 'consumer:' .. role, ARGV[4])
local ack = tonumber(redis.call('HGET', KEYS[1], 'ack:' .. role) or '0')
for n = ack + 1, after do
  local field = 'body:' .. role .. ':' .. n
  local value = redis.call('HGET', KEYS[1], field)
  if value then redis.call('HINCRBY', KEYS[1], 'bytes:' .. role, -string.len(value)) end
  redis.call('HDEL', KEYS[1], field)
end
ack = math.max(ack, after)
redis.call('HSET', KEYS[1], 'ack:' .. role, ack)
local messages = {}
local bytes = 0
for n = ack + 1, seq do
  local value = redis.call('HGET', KEYS[1], 'body:' .. role .. ':' .. n)
  if value then
    if #messages >= 8 or bytes + string.len(value) > 3145728 then break end
    table.insert(messages, {seq=n, body=value})
    bytes = bytes + string.len(value)
  end
end
if #messages == 0 then return {200, '[]'} end
return {200, cjson.encode(messages)}
`;
const revoke = auth + `
redis.call('DEL', KEYS[1])
redis.call('PUBLISH', KEYS[1] .. ':notify:home', 'closed')
redis.call('PUBLISH', KEYS[1] .. ':notify:work', 'closed')
return {200}
`;

export class RedisRelayStore {
    constructor(redis, { ttl = 8 * 60 * 60 * 1000, pollTimeout = 20000 } = {}) {
        Object.assign(this, { redis, ttl, pollTimeout });
    }
    key(id) { return `markview:{${id}}`; }
    async health() {
        if (await this.redis.command(['PING']) !== 'PONG') throw Object.assign(new Error('The relay store is unavailable.'), { status: 503 });
    }
    async evaluate(id, script, ...args) { return this.redis.command(['EVAL', script, '1', this.key(id), ...args.map(String)]); }
    async register(id, homeHash, workHash) {
        const result = await this.evaluate(id, register, homeHash, workHash, this.ttl);
        return { status: result[0] };
    }
    async append(id, role, hash, message) {
        const result = await this.evaluate(id, append, role, hash, message.id, message.hash, message.body);
        return { status: result[0], ...(result[1] === undefined ? {} : { seq: result[1] }) };
    }
    async read(id, role, hash, after, consumer) {
        const result = await this.evaluate(id, read, role, hash, after, consumer);
        return { status: result[0], ...(result[0] === 200 ? { messages: JSON.parse(result[1]) } : {}) };
    }
    async receive(id, role, hash, after, consumer, signal) {
        let result = await this.read(id, role, hash, after, consumer);
        if (result.status !== 200 || result.messages.length || signal?.aborted) return result;
        const subscription = await this.redis.subscribe(this.key(id) + ':notify:' + role, this.pollTimeout, signal);
        try {
            // Subscribe before the second read: a publish between the first read and subscription
            // must be observed by the read, or by the subscription, without a lost wake-up.
            result = await this.read(id, role, hash, after, consumer);
            if (result.status !== 200 || result.messages.length) return result;
            await subscription.changed;
            return await this.read(id, role, hash, after, consumer);
        } finally { subscription.close(); }
    }
    async revoke(id, hash) {
        const result = await this.evaluate(id, revoke, 'home', hash);
        return { status: result[0] };
    }
    close() {}
}
