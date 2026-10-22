import assert from "node:assert/strict";
import { test } from "node:test";
import worker from "../src/index.ts";
import { allowedSender, extractCode, mailbox } from "../src/extract.ts";

async function data(response: Response): Promise<Record<string, string | boolean>> { return await response.json() as Record<string, string | boolean>; }
const secret = "fixture-not-a-real-secret-0123456789";
function fixture() {
  const values = new Map<string, string>();
  const MAIL = {
    async put(key: string, value: string) { values.set(key, value); },
    async get(key: string, type?: string) { const value = values.get(key); return value ? (type === "json" ? JSON.parse(value) : value) : null; },
    async delete(key: string) { values.delete(key); },
  };
  const env = { MAIL, API_KEY: secret, DOMAIN: "example.com", FORWARD_TO: "owner@icloud.com" };
  const request = (path: string, data: object, token = secret) => worker.fetch(new Request(`https://mail.example.com${path}`, { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(data) }), env as Parameters<typeof worker.fetch>[1]);
  return { env, request, values };
}
function mail(to: string, body: string, from = "login@anthropic.com") {
  let forwards = 0;
  const raw = new TextEncoder().encode(`From: ${from}\r\nTo: ${to}\r\nSubject: Login code\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n${body}`);
  return { message: { to, from, rawSize: raw.length, raw: new ReadableStream({ start(c) { c.enqueue(raw); c.close(); } }), async forward() { forwards++; return { messageId: "fixture" }; } }, forwards: () => forwards };
}
test("code extraction rejects ambiguity and unrelated numbers", () => {
  assert.equal(extractCode("Your verification code: 123456", ""), "123456");
  assert.equal(extractCode("", "123456 is your login code"), "123456");
  assert.equal(extractCode("", "Invoice 123456"), null);
  assert.equal(extractCode("Verification code: 123456", "Security code: 654321"), null);
  assert.equal(mailbox("other@evil.com", "example.com"), null);
  assert.equal(allowedSender("a@anthropic.com.evil.com"), false);
});
test("unauthorized, oversized, expired and wrong methods rejected", async () => {
  const f = fixture();
  assert.equal((await f.request("/watch", { email: "a@example.com" }, "wrong")).status, 401);
  assert.equal((await f.request("/watch", { email: "a@evil.com" })).status, 400);
  assert.equal((await f.request("/watch", { email: "a@example.com", padding: "a".repeat(3000) })).status, 400);
  assert.equal((await f.request("/read", { id: crypto.randomUUID() })).status, 410);
});
test("only actively watched recipient is extracted and forwarding remains", async () => {
  const f = fixture();
  const { id } = await data(await f.request("/watch", { email: "a@example.com" }));
  const wrong = mail("b@example.com", "Your verification code: 123456");
  await worker.email(wrong.message, f.env as Parameters<typeof worker.email>[1]);
  assert.equal(wrong.forwards(), 1);
  assert.equal((await data(await f.request("/read", { id }))).waiting, true);
  const right = mail("a@example.com", "Your verification code: 123456");
  await worker.email(right.message, f.env as Parameters<typeof worker.email>[1]);
  assert.equal(right.forwards(), 1);
  const result = await data(await f.request("/read", { id }));
  assert.equal(result.code, "123456"); assert.equal(result.email, "a@example.com");
  await f.request("/stop", { id });
  assert.equal((await f.request("/read", { id })).status, 410);
});
test("unrecognized sender still forwards without exposing code", async () => {
  const f = fixture();
  const { id } = await data(await f.request("/watch", { email: "a@example.com" }));
  const untrusted = mail("a@example.com", "Verification code: 123456", "bad@evil.com");
  await worker.email(untrusted.message, f.env as Parameters<typeof worker.email>[1]);
  assert.equal(untrusted.forwards(), 1);
  assert.equal((await data(await f.request("/read", { id }))).waiting, true);
});
test("expired watch is not processed", async () => {
  const f = fixture();
  await f.request("/watch", { email: "a@example.com" });
  for (const [key, value] of f.values) { const v = JSON.parse(value); v.expiresAt = 0; f.values.set(key, JSON.stringify(v)); }
  const m = mail("a@example.com", "Verification code: 123456");
  await worker.email(m.message, f.env as Parameters<typeof worker.email>[1]);
  assert.equal(m.forwards(), 1); assert.equal([...f.values.keys()].some(k => k.startsWith("result:")), false);
});

test("login link is unique, official and bound to recipient", async () => {
  const { extractLoginURL } = await import("../src/extract.ts");
  const address = "sky@example.com";
  const url = `https://claude.ai/magic-link#${"a".repeat(32)}:${btoa(address)}`;
  assert.equal(extractLoginURL(url, `<a href="${url}">Sign in</a>`, address), url);
  assert.equal(extractLoginURL(url, "", "other@example.com"), null);
  for (const invalid of [url.replace("claude.ai", "claude.ai.evil.com"), url.replace("https:", "http:"), url.replace("magic-link#", "magic-link?redirect=evil#"), url.replace("claude.ai", "user@claude.ai")]) {
    assert.equal(extractLoginURL(invalid, "", address), null);
  }
  assert.equal(extractLoginURL(url + "\n" + url.replace("a".repeat(32), "b".repeat(32)), "", address), null);
});

test("received login-link email returns link while preserving forwarding", async () => {
  const f = fixture();
  const { id } = await data(await f.request("/watch", { email: "sky@example.com" }));
  const link = `https://claude.ai/magic-link#${"c".repeat(32)}:${btoa("sky@example.com")}`;
  const incoming = mail("sky@example.com", `Sign in to Claude\n${link}`);
  await worker.email(incoming.message, f.env as Parameters<typeof worker.email>[1]);
  const result = await data(await f.request("/read", { id }));
  assert.equal(result.loginURL, link); assert.equal(result.manual, false);
  assert.equal(incoming.forwards(), 1);
});
