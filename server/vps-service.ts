import { realpathSync } from "node:fs";
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";
import { UserError, privateHeaders } from "../app/lib/errors.ts";
import { getSqlite } from "../db/index.ts";
import { POST as createRemote } from "../app/api/remote-subscriptions/route.ts";
import { GET as getRemote, PUT as updateRemote, DELETE as deleteRemote } from "../app/api/remote-subscriptions/[id]/route.ts";
import { GET as downloadRemote } from "../app/remote-sub/[id]/[key]/route.ts";

export function startVpsService(port = Number(process.env.PORT ?? 19480)) {
  const origin = process.env.PUBLIC_ORIGIN ?? "https://node.tangchen02.top";
  const limits = new Map<string, { count: number; expiry: number }>();
  let active = 0;
  const server = createServer(async (req, res) => {
    if (++active > 16) { active--; res.writeHead(503); res.end("busy"); return; }
    try {
      const method = req.method ?? "GET";
      const url = new URL(req.url ?? "/", origin);
      if (method === "GET" && url.pathname === "/api/health") { getSqlite().prepare("SELECT 1").get(); res.writeHead(200, { ...privateHeaders, "Content-Type": "application/json" }); res.end('{"status":"ok"}'); return; }
      if (method === "GET" && url.pathname === "/") { res.writeHead(200, privateHeaders); res.end("cc assistant subscription service"); return; }
      const requestOrigin = req.headers.origin;
      if (requestOrigin && requestOrigin !== origin || req.headers["sec-fetch-site"] === "cross-site") throw new UserError("拒绝跨站请求。", 403);
      const ip = String(req.headers["x-real-ip"] ?? "local");
      const now = Date.now();
      for (const [key, value] of limits) if (value.expiry <= now) limits.delete(key);
      if (!limits.has(ip) && limits.size >= 4096) throw new UserError("请求过多。", 429);
      const budget = limits.get(ip) ?? { count: 0, expiry: now + 60_000 };
      budget.count++; limits.set(ip, budget);
      if (budget.count > 120) throw new UserError("请求过多。", 429);
      const write = ["POST", "PUT", "DELETE"].includes(method);
      if (write && !(req.headers["content-type"] ?? "").startsWith("application/json")) throw new UserError("请求必须为 JSON。", 415);
      let body: Buffer | undefined;
      if (["POST", "PUT"].includes(method)) {
        const chunks: Buffer[] = []; let size = 0;
        for await (const chunk of req) { size += chunk.length; if (size > 2_097_152) throw new UserError("内容超过限制。", 413); chunks.push(Buffer.from(chunk)); }
        body = Buffer.concat(chunks);
      }
      const headers = new Headers();
      for (const [name, value] of Object.entries(req.headers)) if (value) headers.set(name, Array.isArray(value) ? value.join(", ") : value);
      const request = new Request(url, { method, headers, ...(body ? { body: Uint8Array.from(body).buffer } : {}) });
      let response: Response;
      const record = /^\/api\/remote-subscriptions\/([a-f0-9]{32})$/.exec(url.pathname);
      const subscription = /^\/remote-sub\/([a-f0-9]{32})\/([a-f0-9]{64})(?:\/[^/]+)?$/.exec(url.pathname);
      if (method === "POST" && url.pathname === "/api/remote-subscriptions") {
        const count = getSqlite().prepare("SELECT count(*) AS count FROM remote_caches").get()?.count;
        if (Number(count) >= 1000) throw new UserError("当前服务配置数量已达到限制。", 413);
        response = await createRemote(request);
      } else if (record && ["GET", "PUT", "DELETE"].includes(method)) {
        const context = { params: Promise.resolve({ id: record[1] }) };
        response = await (method === "GET" ? getRemote : method === "PUT" ? updateRemote : deleteRemote)(request, context);
      } else if (subscription && method === "GET") response = await downloadRemote(request, { params: Promise.resolve({ id: subscription[1], key: subscription[2] }) });
      else throw new UserError("地址不存在。", 404);
      res.writeHead(response.status, Object.fromEntries(response.headers.entries()));
      res.end(Buffer.from(await response.arrayBuffer()));
    } catch (error) {
      res.writeHead(error instanceof UserError ? error.status : 500, { ...privateHeaders, "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: error instanceof UserError ? error.message : "服务暂不可用。" }));
    } finally { active--; }
  });
  server.requestTimeout = 25_000; server.headersTimeout = 10_000;
  server.listen(port, "127.0.0.1");
  return server;
}
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const server = startVpsService();
  process.on("SIGTERM", () => { server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 3000).unref(); });
}
