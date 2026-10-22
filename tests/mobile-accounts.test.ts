import assert from 'node:assert/strict';
import test from 'node:test';
import { changeDeleted, daysUntilExpiry, mergeState, parseState, readState, saveAccount, storageKey, writeState } from '../website/accounts/accounts-core.js';

class MemoryStorage {
  data = new Map<string, string>();
  getItem(key: string) { return this.data.get(key) ?? null; }
  setItem(key: string, value: string) { this.data.set(key, value); }
}
const now = new Date('2026-10-20T08:00:00Z');
const fields = (email = 'a@example.com') => ({ email, label: '账号', status: '备用', subscription: 'Pro', expiresAt: null, createdAt: now.toISOString(), notes: '' });
const empty = () => ({ version: 1, accounts: [] });

test('phone records persist and edit with the same id, normalized email and native-compatible dates', () => {
  const storage = new MemoryStorage();
  const saved = writeState(storage, saveAccount(empty(), fields(' A@Example.com '), null, now));
  const id = saved.accounts[0].id;
  assert.equal(saved.accounts[0].email, 'a@example.com');
  assert.equal(saved.accounts[0].createdAt, '2026-10-20T08:00:00Z');
  const edited = writeState(storage, saveAccount(saved, { ...fields(), label: '更新', status: '使用中' }, id, now));
  assert.deepEqual(readState(storage), edited);
  assert.equal(edited.accounts.length, 1);
  assert.equal(edited.accounts[0].id, id);
  assert.equal(edited.accounts[0].label, '更新');
});
test('recoverable delete survives reload and restore rejects duplicate active emails', () => {
  const storage = new MemoryStorage();
  let state = saveAccount(empty(), fields(), null, now);
  const id = state.accounts[0].id;
  state = writeState(storage, changeDeleted(state, id, true, now));
  assert.equal(readState(storage).accounts[0].deletedAt, '2026-10-20T08:00:00Z');
  state = saveAccount(state, fields(), null, now);
  const before = JSON.stringify(state);
  assert.throws(() => changeDeleted(state, id, false, now), /重复/);
  assert.equal(JSON.stringify(state), before);
  state = changeDeleted(state, state.accounts[1].id, true, now);
  assert.equal(changeDeleted(state, id, false, now).accounts.filter((r: { deletedAt: string | null }) => !r.deletedAt).length, 1);
});
test('malformed, future and oversized files do not replace existing browser storage', () => {
  const storage = new MemoryStorage();
  for (const raw of ['broken', '{"version":2,"accounts":[]}', ' '.repeat(4 * 1024 * 1024 + 1)]) {
    storage.setItem(storageKey, raw);
    assert.throws(() => readState(storage));
    assert.equal(storage.getItem(storageKey), raw);
  }
});
test('quota failures leave caller state unchanged and duplicate input cannot write', () => {
  const state = saveAccount(empty(), fields(), null, now), before = JSON.stringify(state);
  assert.throws(() => saveAccount(state, fields('A@EXAMPLE.COM'), null, now), /重复/);
  const next = saveAccount(state, fields('b@example.com'), null, now);
  assert.throws(() => writeState({ setItem() { throw new Error('quota'); } }, next), /quota/);
  assert.equal(JSON.stringify(state), before);
  assert.throws(() => saveAccount(state, fields(), crypto.randomUUID(), now), /不存在/);
});
test('import merges new records, skips identical copies, rejects conflicts without partial import', () => {
  const first = saveAccount(empty(), fields(), null, now);
  assert.deepEqual(mergeState(first, first), first);
  const incoming = saveAccount(empty(), fields('b@example.com'), null, now);
  assert.equal(mergeState(first, incoming).accounts.length, 2);
  const updated = saveAccount(first, { ...fields(), subscription: 'Max' }, first.accounts[0].id, now);
  assert.throws(() => mergeState(first, updated), /不同版本/);
  assert.throws(() => mergeState(first, saveAccount(empty(), fields(), null, now)), /重复/);
  assert.equal(first.accounts.length, 1);
});
test('Mac backups with uppercase UUIDs and omitted optional dates import, unknown fields are not stored', () => {
  const native = { version: 1, accounts: [{ id: 'AABBCCDD-1111-2222-3333-444444444444', email: 'a@example.com', label: '', status: '使用中', subscription: '', createdAt: '2026-10-20T08:00:00Z', updatedAt: '2026-10-20T08:00:00Z', notes: '', unexpected: 'discard' }] };
  const row = parseState(JSON.stringify(native)).accounts[0];
  assert.equal(row.id, 'aabbccdd-1111-2222-3333-444444444444');
  assert.equal(row.expiresAt, null);
  assert.equal(row.deletedAt, null);
  assert.equal('unexpected' in row, false);
});
test('expiry is based on calendar dates rather than elapsed hours and missing dates stay unknown', () => {
  const late = new Date(2026, 2, 7, 23, 55), early = new Date(2026, 2, 8, 1, 0);
  assert.equal(daysUntilExpiry(early.toISOString(), late), 1);
  assert.equal(daysUntilExpiry(null, late), null);
  assert.equal(daysUntilExpiry(late.toISOString(), late), 0);
});
