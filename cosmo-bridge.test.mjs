import test from 'node:test';
import assert from 'node:assert/strict';
import { installCosmoBridge, summarizeRhythm, COSMO_ORIGIN } from './cosmo-bridge.js';

const channel = '12345678-1234-1234-1234-123456789abc';
const id = '12345678-1234-1234-1234-123456789def';
function setup(overrides = {}) {
  const replies = [];
  let listener;
  const peer = { postMessage: (data, origin) => replies.push({ data, origin }) };
  const host = { opener: peer, addEventListener: (_, fn) => { listener = fn; }, removeEventListener() {} };
  let writes = 0;
  const bridge = installCosmoBridge({ host,
    getSession: () => ({ access_token: 'never-send-this' }),
    getState: () => ({ date: '2026-10-17', now: { title: 'Movement', transition_cue: 'Walk Luna', owner_id: 'private' }, next: { title: 'Evening' }, foodLog: { private: true } }),
    refresh: async () => {}, converse: async () => { writes++; return 'Made it easier.'; }, ...overrides,
  });
  const send = (data, origin = COSMO_ORIGIN, source = peer) => listener({ data, origin, source });
  return { replies, send, bridge, writes: () => writes };
}
const connect = { type: 'cosmo:connect', channel };
const request = { type: 'cosmo:request', channel, id, action: 'conversation', message: 'Make today easier' };

test('only the exact Cosmo origin and opener can connect', async () => {
  const t = setup();
  await t.send(connect, 'https://evil.example');
  await t.send(connect, COSMO_ORIGIN, {});
  await t.send(request);
  assert.equal(t.replies.length, 0);
  assert.equal(t.writes(), 0);
});
test('summary excludes credentials, owner IDs, food history and arbitrary fields', async () => {
  const t = setup(); await t.send(connect);
  assert.equal(t.replies[0].origin, COSMO_ORIGIN);
  const serialized = JSON.stringify(t.replies);
  assert.ok(!serialized.includes('never-send-this'));
  assert.ok(!serialized.includes('private'));
  assert.equal(t.replies[0].data.state.now.title, 'Movement');
  assert.equal(summarizeRhythm(null), null);
});
test('signed-out requests cannot read state or invoke actions', async () => {
  const t = setup({ getSession: () => null }); await t.send(connect); await t.send(request);
  assert.equal(t.replies[0].data.state, null);
  assert.equal(t.replies.at(-1).data.ok, false);
  assert.equal(t.writes(), 0);
});
test('conversation returns the real reply and ignores duplicate request IDs', async () => {
  const t = setup(); await t.send(connect); await t.send(request); await t.send(request);
  assert.equal(t.writes(), 1);
  assert.equal(t.replies.find(r => r.data.type === 'rhythm:reply').data.message, 'Made it easier.');
});
test('unsupported actions, wrong channels, and oversized messages cannot mutate', async () => {
  const t = setup(); await t.send(connect);
  await t.send({ ...request, action: 'reset_today' });
  await t.send({ ...request, channel: 'wrong-channel' });
  await t.send({ ...request, message: 'x'.repeat(501) });
  assert.equal(t.writes(), 0);
});
test('concurrent requests do not run competing changes', async () => {
  let finish;
  const t = setup({ converse: () => new Promise(resolve => { finish = resolve; }) });
  await t.send(connect);
  const first = t.send(request);
  await t.send({ ...request, id: '12345678-1234-1234-1234-123456789aaa' });
  assert.match(t.replies.at(-1).data.error, /previous request/);
  finish('Done'); await first;
});
test('failures return errors rather than claiming a successful save', async () => {
  const t = setup({ converse: async () => { throw new Error('Network unavailable'); } });
  await t.send(connect); await t.send(request);
  assert.equal(t.replies.at(-1).data.ok, false);
  assert.equal(t.replies.at(-1).data.error, 'Network unavailable');
});
test('sign-out during an in-flight request suppresses its state and reply', async () => {
  let signedIn = true;
  const t = setup({ getSession: () => signedIn ? { user: { id: 'owner' } } : null,
    converse: async () => { signedIn = false; return 'Private reply'; } });
  await t.send(connect); await t.send(request);
  const response = t.replies.find(r => r.data.type === 'rhythm:reply').data;
  assert.equal(response.ok, false);
  assert.ok(!JSON.stringify(response).includes('Private reply'));
  assert.equal(t.replies.at(-1).data.state, null);
});
