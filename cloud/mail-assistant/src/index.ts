import PostalMime from "postal-mime";
import { allowedSender, extractCode, extractLoginURL, mailbox } from "./extract.ts";

// Inferred from the typed deployment configuration, rather than duplicating bindings.
import type config from "../cloudflare.config.ts";
import type { InferEnv } from "cf/config";
type Env = InferEnv<typeof config.worker>;
type Watch = { id: string; email: string; expiresAt: number };
const lifetime = 600;
const json = (body: object, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
async function hash(value: string) {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))), b => b.toString(16).padStart(2, "0")).join("");
}
async function authorized(request: Request, secret: string) {
  if (!secret || secret.length < 32) return false;
  const supplied = request.headers.get("Authorization")?.replace(/^Bearer /, "") ?? "";
  if (supplied.length > 256) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
  const data = new TextEncoder().encode("cc-mail-assistant");
  const signature = await crypto.subtle.sign("HMAC", key, data);
  const candidate = await crypto.subtle.importKey("raw", new TextEncoder().encode(supplied || "missing"), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  return crypto.subtle.verify("HMAC", candidate, signature, data);
}
async function bounded(stream: ReadableStream<Uint8Array> | null, limit: number): Promise<Uint8Array> {
  if (!stream) throw new Error("empty");
  const reader = stream.getReader(); const chunks: Uint8Array[] = []; let length = 0;
  try {
    while (true) {
      const { value, done } = await reader.read(); if (done) break;
      length += value.length;
      if (length > limit) { await reader.cancel(); throw new Error("too large"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const all = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { all.set(chunk, offset); offset += chunk.length; }
  return all;
}

const worker = {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (!(await authorized(request, env.API_KEY))) return json({ error: "unauthorized" }, 401);
    if (request.method !== "POST") return json({ error: "method" }, 405);
    try {
      const input = JSON.parse(new TextDecoder().decode(await bounded(request.body, 2048)));
      const path = new URL(request.url).pathname.replace(/^\/apps\/cc-assistant\/mail-api(?=\/)/, "");
      if (path === "/watch") {
        const email = mailbox(input.email, env.DOMAIN); if (!email) return json({ error: "invalid mailbox" }, 400);
        const id = crypto.randomUUID(); const expiresAt = Date.now() + lifetime * 1000;
        const watch = { id, email, expiresAt };
        await env.MAIL.put(`watch:${await hash(email)}`, JSON.stringify(watch), { expirationTtl: lifetime });
        await env.MAIL.put(`session:${id}`, JSON.stringify(watch), { expirationTtl: lifetime });
        return json({ id, expiresAt });
      }
      if (!["/read", "/stop"].includes(path) || typeof input.id !== "string" || !/^[0-9a-f-]{36}$/.test(input.id)) return json({ error: "invalid request" }, 400);
      const watch = await env.MAIL.get<Watch>(`session:${input.id}`, "json");
      if (!watch || watch.expiresAt <= Date.now()) return json({ error: "expired" }, 410);
      if (path === "/stop") {
        await env.MAIL.delete(`session:${input.id}`); await env.MAIL.delete(`result:${input.id}`);
        // Leave the short-lived address watch in place: deleting it could cancel a newer session.
        return json({ stopped: true });
      }
      const result = await env.MAIL.get<object>(`result:${input.id}`, "json");
      return json(result ?? { waiting: true });
    } catch { return json({ error: "request failed" }, 400); }
  },
  async email(message: Pick<ForwardableEmailMessage, "to" | "rawSize" | "raw" | "forward">, env: Env): Promise<void> {
    // Forwarding is independent of parsing/storage; parser failures never suppress the iCloud copy.
    await message.forward(env.FORWARD_TO);
    try {
      const email = mailbox(message.to, env.DOMAIN);
      if (!email || message.rawSize > 512 * 1024) return;
      const watch = await env.MAIL.get<Watch>(`watch:${await hash(email)}`, "json");
      if (!watch || watch.expiresAt <= Date.now() || !(await env.MAIL.get(`session:${watch.id}`))) return;
      const parsed = await PostalMime.parse(await bounded(message.raw, 512 * 1024));
      const sender = parsed.from?.address ?? "";
      if (!allowedSender(sender)) return;
      const code = extractCode(parsed.subject ?? "", parsed.text ?? "");
      const loginURL = extractLoginURL(parsed.text ?? "", parsed.html ?? "", email);
      const remaining = Math.floor((watch.expiresAt - Date.now()) / 1000);
      if (remaining < 60) return;
      await env.MAIL.put(`result:${watch.id}`, JSON.stringify({ code, loginURL, receivedAt: Date.now(), sender, email, manual: !code && !loginURL }), { expirationTtl: remaining });
    } catch { console.warn(JSON.stringify({ event: "mail_extract_failed" })); }
  },
};

export default worker;
