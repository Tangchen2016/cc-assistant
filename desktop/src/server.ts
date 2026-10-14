import { randomBytes, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import { readFile, realpath, stat } from "node:fs/promises";
import { dirname, extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { UserError, privateHeaders } from "../../app/lib/errors.ts";
import { validateSourceUrl } from "../../app/lib/source.ts";
import { validateProfile, transformSource } from "../../app/lib/profile.ts";
import { validatePingRequest } from "../../app/lib/ping.ts";
import { titleFilename } from "../../app/lib/subscription-name.ts";
import { fetchLocalSource } from "./local-source.ts";
import { pingNodeDelay, cancelNodeDelays } from "./node-delay.ts";
import { LocalStore } from "./local-store.ts";
import { RemotePublisher } from "./remote-share.ts";
import type { RemoteOptions } from "./remote-share.ts";

type Options = { port?: number; store?: LocalStore; assets?: string; fetchSource?: typeof fetchLocalSource; ping?: typeof pingNodeDelay; remote?: RemoteOptions };
const mime: Record<string, string> = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon", ".woff2": "font/woff2" };
const bearer = (request: IncomingMessage) => {
  const key = /^Bearer ([a-f0-9]{64})$/.exec(request.headers.authorization ?? "")?.[1];
  if (!key) throw new UserError("管理密钥无效或缺失。", 401);
  return key;
};

async function body(request: IncomingMessage) {
  if (Number(request.headers["content-length"]) > 65_536) throw new UserError("配置过大。", 413);
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 65_536) throw new UserError("配置过大。", 413);
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown; }
  catch { throw new UserError("请求必须为有效 JSON。"); }
}

export function validateRequest(request: IncomingMessage, port: number) {
  const hosts = [`127.0.0.1:${port}`, `localhost:${port}`];
  if (!hosts.includes(request.headers.host ?? "")) throw new UserError("仅允许本机访问。", 403);
  const origin = request.headers.origin;
  if (origin && !hosts.some((host) => origin === `http://${host}`)) throw new UserError("拒绝跨站请求。", 403);
  if (["cross-site", "same-site"].includes(String(request.headers["sec-fetch-site"]))) throw new UserError("拒绝跨站请求。", 403);
  if (!["GET", "HEAD"].includes(request.method ?? "")) {
    if (!origin || origin !== `http://${request.headers.host}`) throw new UserError("写入操作需要来自 App 本机页面。", 403);
    if (!/^application\/json(?:\s*;|$)/i.test(request.headers["content-type"] ?? "")) throw new UserError("写入操作必须为 JSON。", 415);
  }
}

function reply(response: ServerResponse, value: unknown, status = 200) {
  response.writeHead(status, { ...privateHeaders, "Content-Type": "application/json; charset=utf-8", "X-Frame-Options": "DENY" });
  response.end(JSON.stringify(value));
}

export async function startDesktopServer(options: Options = {}) {
  const configuredPort = options.port ?? Number(process.env.PORT ?? 19473);
  if (!Number.isInteger(configuredPort) || configuredPort < 0 || configuredPort > 65_535) throw new UserError("本地服务端口无效。", 500);
  const store = options.store ?? await new LocalStore().load();
  const assets = resolve(options.assets ?? process.env.DESKTOP_ASSETS_DIR ?? resolve(dirname(fileURLToPath(import.meta.url)), "../public"));
  const fetcher = options.fetchSource ?? fetchLocalSource;
  const ping = options.ping ?? pingNodeDelay;
  const publisher = new RemotePublisher(store, { ...options.remote, ...(options.fetchSource && !options.remote?.fetchSource ? { fetchSource: options.fetchSource } : {}) });
  let boundPort = configuredPort;
  const session = randomBytes(32).toString("hex");
  const server = createServer(async (request, response) => {
    try {
      validateRequest(request, boundPort);
      const url = new URL(request.url ?? "/", `http://127.0.0.1:${boundPort}`);
      const method = request.method ?? "GET";
      const path = url.pathname;
      if (path.startsWith("/api/")) {
        const cookie = /(?:^|;\s*)studio_session=([a-f0-9]{64})(?:;|$)/.exec(request.headers.cookie ?? "")?.[1];
        if (!cookie || !timingSafeEqual(Buffer.from(cookie, "hex"), Buffer.from(session, "hex"))) throw new UserError("请从 App 页面访问本地资料。", 401);
      }
      if (path === "/api/desktop" && method === "GET") { reply(response, await store.library()); return; }
      if (path === "/api/desktop/draft" && method === "PUT") { reply(response, await store.draft(await body(request))); return; }
      if (path === "/api/inspect" && method === "POST") {
        const input = await body(request) as { sourceUrl?: unknown };
        const sourceUrl = validateSourceUrl(input?.sourceUrl).href;
        const { config, fetchedAt, sourceName } = await fetcher(sourceUrl);
        const groups = (config["proxy-groups"] ?? []) as Array<{ name: string }>;
        reply(response, { nodes: config.proxies.map(({ name, type }) => ({ name, type })), sourceGroups: groups.map(({ name }) => name), fetchedAt, sourceName }); return;
      }
      if (path === "/api/ping" && method === "POST") {
        const input = await body(request);
        const { sourceUrl, nodes } = validatePingRequest(input);
        const chainEntry = (input as { chainEntry?: unknown }).chainEntry;
        if (chainEntry !== undefined && (typeof chainEntry !== "string" || !chainEntry.trim() || chainEntry.length > 256 || /[\x00-\x1f\x7f]/.test(chainEntry))) throw new UserError("链式入口节点名称无效。");
        const controller = new AbortController();
        const cancel = () => { if (!response.writableEnded) controller.abort(); };
        response.once("close", cancel);
        try {
          const { config } = await fetcher(sourceUrl);
          controller.signal.throwIfAborted();
          reply(response, await ping(config, nodes, { signal: controller.signal, ...(chainEntry !== undefined ? { chainEntry: chainEntry as string } : {}) }));
        }
        finally { response.removeListener("close", cancel); }
        return;
      }
      if (path === "/api/profiles" && method === "POST") {
        const profile = validateProfile(await body(request));
        const { config } = await fetcher(profile.sourceUrl);
        transformSource(config, profile);
        reply(response, await store.create(profile), 201); return;
      }
      const remoteRoute = /^\/api\/profiles\/([a-f0-9]{32})\/remote$/.exec(path);
      if (remoteRoute) {
        const id = remoteRoute[1], key = bearer(request);
        await store.find(id, key);
        if (method === "POST") { await body(request); reply(response, { remote: await publisher.publish(id, key, true) }); return; }
        if (method === "DELETE") { reply(response, await publisher.remove(id, key)); return; }
      }
      const profileRoute = /^\/api\/profiles\/([a-f0-9]{32})$/.exec(path);
      if (profileRoute) {
        const id = profileRoute[1];
        const key = bearer(request);
        if (method === "GET") { const { profile, remote } = await store.find(id, key); reply(response, { profile, ...(remote ? { remote } : {}) }); return; }
        if (method === "DELETE") { reply(response, await publisher.serialize(id, async () => { const record = await store.find(id, key); if (record.remote) throw new UserError("请先停用远程订阅，再删除本机配置。", 409); return store.remove(id, key); })); return; }
        if (method === "PUT") {
          await store.find(id, key);
          const profile = validateProfile(await body(request));
          const { config } = await fetcher(profile.sourceUrl);
          transformSource(config, profile);
          await publisher.serialize(id, () => store.update(id, key, profile));
          const record = await store.find(id, key);
          if (record.remote) { try { await publisher.publish(id, key); } catch { /* Local save remains valid when cloud sync fails. */ } }
          const remote = (await store.find(id, key)).remote;
          reply(response, { saved: true, ...(remote ? { remote } : {}) }); return;
        }
      }
      const subscription = /^\/sub\/([a-f0-9]{32})\/([a-f0-9]{64})(?:\/[^/]+)?$/.exec(path);
      if (subscription && method === "GET") {
        const { profile } = await store.find(subscription[1], subscription[2], true);
        // Only descriptors are persisted. Every client refresh fetches the source anew.
        const { config, userInfo } = await fetcher(profile.sourceUrl);
        const { yaml, warnings } = transformSource(config, profile);
        response.writeHead(200, {
          ...privateHeaders, "Content-Type": "application/yaml; charset=utf-8", "Content-Disposition": titleFilename(profile.name),
          "X-Subscription-Warnings": String(warnings.length), ...(userInfo ? { "Subscription-Userinfo": userInfo } : {}),
        });
        response.end(yaml); return;
      }
      if (path.startsWith("/api/") || path.startsWith("/sub/") || !["GET", "HEAD"].includes(method)) throw new UserError("地址不存在。", 404);
      let decoded: string;
      try { decoded = decodeURIComponent(path); } catch { throw new UserError("无效地址。", 400); }
      if (decoded.includes("\0") || decoded.includes("\\") || decoded.split("/").some((part) => part === "..")) throw new UserError("地址不存在。", 404);
      const requested = resolve(assets, `.${decoded === "/" ? "/index.html" : decoded}`);
      if (!requested.startsWith(`${assets}${sep}`)) throw new UserError("地址不存在。", 404);
      let file: string;
      try { file = await realpath(requested); } catch { throw new UserError("地址不存在。", 404); }
      const assetRoot = await realpath(assets);
      if (!file.startsWith(`${assetRoot}${sep}`) || !(await stat(file)).isFile()) throw new UserError("地址不存在。", 404);
      response.writeHead(200, { ...privateHeaders, ...(["/", "/index.html"].includes(path) && method === "GET" ? { "Set-Cookie": `studio_session=${session}; HttpOnly; SameSite=Strict; Path=/` } : {}), "Content-Type": mime[extname(file)] ?? "application/octet-stream", "X-Frame-Options": "DENY", "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'" });
      response.end(method === "HEAD" ? undefined : await readFile(file));
    } catch (error) {
      if (!response.headersSent) reply(response, { error: error instanceof UserError ? error.message : "本地服务暂时不可用，请稍后重试。" }, error instanceof UserError ? error.status : 500);
      else response.end();
    }
  });
  server.requestTimeout = 30_000;
  server.headersTimeout = 10_000;
  await new Promise<void>((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(configuredPort, "127.0.0.1", () => { server.removeListener("error", reject); resolveListen(); });
  });
  const address = server.address();
  if (address && typeof address !== "string") boundPort = address.port;
  server.once("close", () => { void publisher.stop(); });
  publisher.start();
  return { server, port: boundPort, store, publisher };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  startDesktopServer().then(({ port, server, publisher }) => {
    process.stdout.write(`${JSON.stringify({ ready: true, port })}\n`);
    const shutdown = () => {
      cancelNodeDelays();
      const deadline = setTimeout(() => { server.closeAllConnections(); process.exit(0); }, 3000);
      const stopped = publisher.stop();
      server.close(() => { void stopped.finally(() => { clearTimeout(deadline); process.exit(0); }); });
    };
    process.once("SIGTERM", shutdown); process.once("SIGINT", shutdown);
  }).catch(() => { process.stderr.write(`${JSON.stringify({ error: "本地服务启动失败，端口可能被占用或资料目录不可用。" })}\n`); process.exitCode = 1; });
}
