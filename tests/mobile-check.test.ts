import assert from 'node:assert/strict';
import test from 'node:test';
import { clearMarkedIP, compareMarkedIP, markerStorageKey, normalizeIP, parseTrace, readMarkedIP, saveMarkedIP } from '../website/check/check-core.js';

class MemoryStorage {
  data = new Map<string, string>();
  getItem(key: string) { return this.data.get(key) ?? null; }
  setItem(key: string, value: string) { this.data.set(key, value); }
  removeItem(key: string) { this.data.delete(key); }
}

test('one marker is replaced, persists after reload, and detects changes across every successful target', () => {
  const storage = new MemoryStorage();
  saveMarkedIP(storage, '203.0.113.10');
  const replacement = saveMarkedIP(storage, '203.0.113.20');
  assert.equal(storage.data.size, 1);
  assert.deepEqual(readMarkedIP(storage), replacement);
  assert.equal(compareMarkedIP([{ ip: '203.0.113.20' }, { error: 'blocked' }], replacement), 'same');
  assert.equal(compareMarkedIP([{ ip: '203.0.113.20' }, { ip: '203.0.113.10' }], replacement), 'changed');
  assert.equal(compareMarkedIP([{ error: 'blocked' }], replacement), 'unknown');
  assert.equal(compareMarkedIP([{ ip: '203.0.113.20' }], null), 'unmarked');
});

test('only one consistent legacy baseline migrates; conflicting old baselines do not pick an arbitrary marker', () => {
  const storage = new MemoryStorage();
  storage.setItem('cc-mobile-egress-baseline-v1', JSON.stringify({ 'claude.ai': '203.0.113.10', 'claude.com': '203.0.113.10' }));
  assert.equal(readMarkedIP(storage)?.ip, '203.0.113.10');
  const conflicting = new MemoryStorage();
  conflicting.setItem('cc-mobile-egress-baseline-v1', JSON.stringify({ 'claude.ai': '203.0.113.10', 'claude.com': '203.0.113.20' }));
  assert.equal(readMarkedIP(conflicting), null);
  assert.equal(conflicting.getItem(markerStorageKey), null);
});

test('clearing never resurrects a legacy marker, even if removing legacy storage fails', () => {
  const storage = new MemoryStorage();
  storage.setItem('cc-mobile-egress-baseline-v1', '{"claude.ai":"203.0.113.10"}');
  readMarkedIP(storage);
  storage.removeItem = () => { throw new Error('blocked'); };
  clearMarkedIP(storage);
  assert.equal(readMarkedIP(storage), null);
});

test('invalid or blocked storage never claims a marker was saved', () => {
  const storage = new MemoryStorage();
  const original = saveMarkedIP(storage, '203.0.113.10');
  assert.throws(() => saveMarkedIP(storage, '999.1.1.1'));
  assert.deepEqual(readMarkedIP(storage), original);
  storage.setItem = () => { throw new Error('quota'); };
  assert.throws(() => saveMarkedIP(storage, '203.0.113.20'));
  assert.deepEqual(readMarkedIP(storage), original);
  assert.throws(() => clearMarkedIP(storage));
});

test('IPv6 comparisons normalize spelling; malformed IP and URL input are rejected', () => {
  assert.equal(normalizeIP('2001:0DB8:0000::1'), '2001:db8::1');
  assert.equal(compareMarkedIP([{ ip: '2001:0db8:0:0:0:0:0:1' }], { ip: '2001:db8::1' }), 'same');
  for (const bad of ['1:2:3', ':', '1.2.3.999', '01.2.3.4', 'https://example.com/', '::1%en0', '<script>']) assert.equal(normalizeIP(bad), null);
});

test('manual trace must identify the actual target and contain valid IP and country; HTML and substituted targets fail', () => {
  assert.deepEqual(parseTrace('h=claude.ai\r\nip=203.0.113.10\r\nloc=US\r\n', 'claude.ai'), { host: 'claude.ai', ip: '203.0.113.10', country: 'US' });
  assert.throws(() => parseTrace('h=claude.com\nip=203.0.113.10\nloc=US', 'claude.ai'), /claude.ai/);
  assert.throws(() => parseTrace('h=claude.ai\nip=999.1.1.1\nloc=US', 'claude.ai'));
  assert.throws(() => parseTrace('h=claude.ai\nip=203.0.113.10\nip=203.0.113.20\nloc=US', 'claude.ai'), /重复/);
  assert.throws(() => parseTrace('<html>challenge</html>', 'claude.ai'));
  assert.throws(() => parseTrace('x'.repeat(8193), 'claude.ai'));
});

test('AI prompt preserves marker comparison and manual/browser failure boundaries without exporting IP or raw error secrets', async () => {
  const { buildAIPrompt } = await import('../website/check/check-core.js');
  const targets = [{ host: 'claude.ai' }, { host: 'claude.com' }, { host: 'platform.claude.com' }];
  const value = buildAIPrompt(targets, [{ host: 'claude.ai', ip: '203.0.113.10', country: 'US', manual: true }, { host: 'claude.com', error: '跨站读取受限 https://example.com/?token=TOPSECRET', attempts: 2 }, { host: 'platform.claude.com', ip: '203.0.113.20', country: 'US' }], { ip: '203.0.113.10' }, '2026/10/19 23:00', 'Safari');
  assert.match(value, /存在与标记不同的出口/);
  assert.match(value, /出口1/);
  assert.match(value, /出口2/);
  assert.match(value, /手动粘贴/);
  assert.match(value, /跨站读取或网络请求受限/);
  assert.match(value, /已自动重试/);
  assert.match(value, /取得我的同意/);
  for (const hidden of ['203.0.113.10', '203.0.113.20', 'TOPSECRET', 'example.com', 'token=']) assert.equal(value.includes(hidden), false);
});

test('timezone offsets keep sign, fractional hours and invalid states; AI reports browser timezone as reference only', async () => {
  const { formatUTCOffset, readBrowserTimeZone, buildAIPrompt } = await import('../website/check/check-core.js');
  assert.equal(formatUTCOffset(345), 'UTC+05:45');
  assert.equal(formatUTCOffset(-210), 'UTC−03:30');
  assert.equal(formatUTCOffset(0), 'UTC+00:00');
  for (const value of [NaN, Infinity, 841, -841, 1.5]) assert.throws(() => formatUTCOffset(value));
  const zone = readBrowserTimeZone();
  assert.ok(zone?.identifier);
  assert.equal(zone.utcOffsetMinutes, -new Date().getTimezoneOffset());
  const prompt = buildAIPrompt([{ host: 'claude.ai' }], [], null, '', 'Safari', { identifier: 'Asia/Kathmandu', utcOffsetMinutes: 345, offsetText: 'UTC+05:45' });
  assert.match(prompt, /Asia\/Kathmandu · UTC\+05:45/);
  assert.match(prompt, /未单独读取系统时区/);
  assert.match(prompt, /不按出口国家推断唯一时区/);
});
