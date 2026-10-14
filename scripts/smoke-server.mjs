import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
const directory = await mkdtemp(join(tmpdir(), 'cc-server-smoke-'));
const base = 'http://127.0.0.1:4181';
let child;
async function start() {
  child = spawn(process.execPath, [resolve('.next/standalone/server.js')], { env: { ...process.env, HOSTNAME: '127.0.0.1', PORT: '4181', DATABASE_PATH: join(directory, 'state.sqlite') }, stdio: 'ignore' });
  for (let i = 0; i < 100; i++) {
    try { const r = await fetch(base + '/api/health'); if (r.ok) return; } catch {}
    if (child.exitCode !== null) throw new Error('Smoke server exited');
    await new Promise(r => setTimeout(r, 100));
  }
  throw new Error('Smoke server not ready');
}
async function stop() {
  if (!child || child.exitCode !== null) return;
  const closed = once(child, 'exit'); child.kill('SIGTERM');
  const timer = setTimeout(() => child.kill('SIGKILL'), 3000);
  await closed; clearTimeout(timer);
}
async function call(path, body, key, method, origin) {
  return fetch(base + path, { method: method || (body ? 'POST' : 'GET'), headers: { 'Content-Type': 'application/json', ...(key ? { Authorization: 'Bearer ' + key } : {}), ...(origin ? { Origin: origin } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
}
try {
  await start();
  const profile = { name: '增强-验收', sourceUrl: 'https://example.com/not-a-subscription', groups: [{ name: 'Claude', nodes: ['US test'] }], rules: [{ type: 'DOMAIN-SUFFIX', value: 'claude.ai', group: 'Claude' }] };
  const cache = { profile, sourceYaml: 'proxies:\n  - {name: US test, type: ss, server: example.com, port: 443, cipher: aes-128-gcm, password: test}\nrules: []\n', sourceFetchedAt: '2026-10-14T00:00:00.000Z' };
  const created = await call('/api/remote-subscriptions', cache); assert.equal(created.status, 201);
  const saved = await created.json();
  let downloaded = await call(saved.subscriptionPath);
  assert.equal(downloaded.status, 200); assert.equal(downloaded.headers.get('x-subscription-source'), 'cache');
  assert.match(await downloaded.text(), /DOMAIN-SUFFIX,claude.ai,Claude/);
  assert.equal((await call('/api/remote-subscriptions/' + saved.id, undefined, saved.downloadKey)).status, 404);
  assert.equal((await call('/api/remote-subscriptions', cache, undefined, undefined, 'https://evil.example')).status, 403);
  assert.equal((await call('/api/inspect', { sourceUrl: 'http://169.254.169.254/' })).status, 400);
  await stop(); await start();
  downloaded = await call(saved.subscriptionPath); assert.equal(downloaded.status, 200);
  profile.name = '增强-改名';
  assert.equal((await call('/api/remote-subscriptions/' + saved.id, cache, saved.manageKey, 'PUT')).status, 200);
  assert.equal((await call(saved.subscriptionPath)).status, 200);
  assert.equal((await call('/api/remote-subscriptions/' + saved.id, undefined, saved.manageKey, 'DELETE')).status, 200);
  console.log('Production smoke passed: SQLite restart, cache download, current rules, separate keys, rename alias, cross-site and private-address rejection.');
} finally { await stop(); await rm(directory, { recursive: true, force: true }); }
