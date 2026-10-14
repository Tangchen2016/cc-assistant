import { spawn, execFile } from "node:child_process";
import { lookup } from "node:dns/promises";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createConnection } from "node:net";
import { UserError } from "../../app/lib/errors.ts";
import { fetchSource, publicDns } from "../../app/lib/source.ts";
import { pingNodes } from "../../app/lib/ping.ts";
import type { SourceConfig } from "../../app/lib/source.ts";

const MAX_BYTES = 2 * 1024 * 1024;
const quote = (value: string) => `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r/g, "\\r").replace(/\n/g, "\\n")}"`;

export async function systemProxy(protocol: string) {
  const env = process.env;
  const explicit = protocol === "https:" ? env.https_proxy ?? env.HTTPS_PROXY : env.http_proxy ?? env.HTTP_PROXY;
  const fallback = env.all_proxy ?? env.ALL_PROXY;
  if (explicit !== undefined || fallback !== undefined) return explicit ?? fallback ?? "";
  if (process.platform !== "darwin") return "";
  const output = await new Promise<string>((resolve) => {
    execFile("/usr/sbin/scutil", ["--proxy"], { timeout: 1500, maxBuffer: 65_536 }, (error, stdout) => resolve(error ? "" : stdout));
  });
  const fields = new Map([...output.matchAll(/^\s*(\w+)\s*:\s*(.*?)\s*$/gm)].map((entry) => [entry[1], entry[2]]));
  const prefix = protocol === "https:" ? "HTTPS" : "HTTP";
  const host = fields.get(`${prefix}Proxy`);
  const port = fields.get(`${prefix}Port`);
  if (fields.get(`${prefix}Enable`) !== "1" || !host || !/^\d+$/.test(port ?? "")) return "";
  if (/[\s/@?#]/.test(host)) return "";
  return `http://${host.includes(":") ? `[${host}]` : host}:${port}`;
}

// Source URLs and proxy credentials enter curl through stdin, never argv or logs.
export async function curlFetch(input: string | URL | Request, options: RequestInit = {}): Promise<Response> {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  const signal = options.signal;
  signal?.throwIfAborted();
  const directory = await mkdtemp(join(tmpdir(), "subscription-studio-"));
  try {
    const headersPath = join(directory, "headers");
    const proxy = await systemProxy(new URL(url).protocol);
    const headers = new Headers(options.headers);
    const config = [
      `url = ${quote(url)}`, 'request = "GET"', 'proto = "=http,https"', 'proto-redir = "=http,https"',
      "max-redirs = 0", "connect-timeout = 8", "max-time = 15", `max-filesize = ${MAX_BYTES}`,
      "silent", "compressed", `dump-header = ${quote(headersPath)}`, `proxy = ${quote(proxy)}`,
      `noproxy = ${quote(process.env.no_proxy ?? process.env.NO_PROXY ?? "")}`,
      ...[...headers.entries()].map(([name, value]) => `header = ${quote(`${name}: ${value}`)}`),
    ].join("\n");
    const body = await new Promise<Buffer>((resolve, reject) => {
      const child = spawn("/usr/bin/curl", ["-q", "--config", "-"], { stdio: ["pipe", "pipe", "ignore"], env: { ...process.env, CURL_HOME: directory } });
      const chunks: Buffer[] = [];
      let size = 0;
      let settled = false;
      const stop = (error: Error) => { if (!settled) { settled = true; child.kill("SIGKILL"); reject(error); } };
      const abort = () => stop(new UserError("拉取源订阅超时或已取消。", 502));
      const timer = setTimeout(abort, 16_000);
      signal?.addEventListener("abort", abort, { once: true });
      child.on("error", () => stop(new UserError("无法启动系统 curl。", 502)));
      child.stdin.on("error", () => undefined);
      child.stdout.on("data", (chunk: Buffer) => {
        size += chunk.length;
        if (size > MAX_BYTES) { stop(new UserError("源订阅超过 2 MiB 限制。", 413)); return; }
        chunks.push(chunk);
      });
      child.on("close", (code) => {
        clearTimeout(timer);
        signal?.removeEventListener("abort", abort);
        if (settled) return;
        settled = true;
        if (code === 63) reject(new UserError("源订阅超过 2 MiB 限制。", 413));
        else if (code !== 0) reject(new UserError(code === 28 ? "本机拉取源订阅超时，请稍后重试。" : "本机无法连接源订阅，请检查网络或系统代理。", 502));
        else resolve(Buffer.concat(chunks));
      });
      child.stdin.end(`${config}\n`);
      if (signal?.aborted) abort();
    });
    const rawHeaders = await readFile(headersPath, "utf8");
    if (rawHeaders.length > 524_288) throw new UserError("源订阅响应头过大。", 502);
    const blocks = rawHeaders.split(/\r?\n\r?\n/).filter((block) => /^HTTP\/\S+\s+\d{3}/.test(block));
    const last = blocks.at(-1);
    if (!last) throw new UserError("源订阅返回无效 HTTP 响应。", 502);
    const status = Number(/^HTTP\/\S+\s+(\d{3})/.exec(last)?.[1]);
    const responseHeaders = new Headers();
    for (const line of last.split(/\r?\n/).slice(1)) {
      const separator = line.indexOf(":");
      if (separator > 0) responseHeaders.append(line.slice(0, separator).trim(), line.slice(separator + 1).trim());
    }
    return new Response([204, 205, 304].includes(status) ? null : new Uint8Array(body), { status, headers: responseHeaders });
  } finally { await rm(directory, { recursive: true, force: true }); }
}

export async function localDns(hostname: string, signal: AbortSignal) {
  signal.throwIfAborted();
  const addresses = await lookup(hostname, { all: true, verbatim: true });
  signal.throwIfAborted();
  const answers = addresses.map(({ address }) => address);
  // Clash fake-IP is routing metadata, not the node's real public address.
  if (answers.some((address) => /^198\.(?:18|19)\./.test(address))) return publicDns(hostname, signal, curlFetch as typeof fetch);
  return answers;
}

export async function fetchLocalSource(url: string) {
  try { return await fetchSource(url, { fetch: curlFetch as typeof fetch, resolve: localDns }); }
  catch (error) {
    if (error instanceof UserError) {
      if (error.message.includes("浏览器验证")) throw new UserError("源订阅要求浏览器验证，本机请求未获放行（HTTP 403）。请尝试服务商提供的其他官方订阅链接。", 502);
      throw new UserError(error.message.replace(/云端请求/g, "本机请求"), error.status);
    }
    throw error;
  }
}

export async function pingLocalNodes(config: SourceConfig, names: string[]) {
  const result = await pingNodes(config, names, {
    resolve: localDns,
    connect: ({ hostname, port }) => {
      const socket = createConnection({ host: hostname, port });
      const opened = new Promise<void>((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
      const closed = new Promise<void>((resolve) => socket.once("close", () => resolve()));
      return { opened, closed, close: () => { socket.destroy(); } };
    },
  });
  return { ...result, results: result.results.map((entry) => ({ ...entry, ...(entry.error ? { error: entry.error.replace(/云端/g, "本机") } : {}) })) };
}
