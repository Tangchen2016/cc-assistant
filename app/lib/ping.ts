import ipaddr from "ipaddr.js";
import { UserError } from "./errors.ts";
import { isPublicAddress, publicDns, validateSourceUrl } from "./source.ts";
import type { SourceConfig } from "./source.ts";

export type PingResult = {
  name: string;
  status: "ok" | "timeout" | "unavailable" | "blocked";
  latencyMs?: number;
  error?: string;
};
type Socket = {
  opened: Promise<unknown>;
  closed?: Promise<unknown>;
  close: () => Promise<void> | void;
};
type PingOptions = {
  connect: (target: { hostname: string; port: number }) => Socket;
  resolve?: (host: string, signal: AbortSignal) => Promise<string[]>;
  dnsTimeoutMs?: number;
  socketTimeoutMs?: number;
};

class ProbeTimeout extends Error {}

export function validatePingRequest(input: unknown) {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new UserError("测速请求格式无效。");
  const value = input as { sourceUrl?: unknown; nodes?: unknown };
  const sourceUrl = validateSourceUrl(value.sourceUrl).href;
  if (!Array.isArray(value.nodes) || value.nodes.length < 1 || value.nodes.length > 10) throw new UserError("每次请选择 1 至 10 个节点测速。");
  const nodes = value.nodes.map((name) => {
    if (typeof name !== "string" || !name.trim() || name.length > 256 || /[\r\n\0]/.test(name)) throw new UserError("节点名称无效。");
    return name;
  });
  if (new Set(nodes).size !== nodes.length) throw new UserError("测速节点不能重复。");
  return { sourceUrl, nodes };
}

function nodeAddress(node: Record<string, unknown>) {
  if (typeof node.server !== "string" || !node.server.trim() || node.server.length > 253) throw new UserError("该节点没有可测速的服务器地址。");
  const server = node.server.replace(/^\[|\]$/g, "").replace(/\.$/, "");
  const literal = ipaddr.isValid(server);
  if (/[\s/?#@%]/.test(server) || !literal && server.includes(":")) throw new UserError("节点服务器地址无效。");
  const url = validateSourceUrl(`https://${literal && server.includes(":") ? `[${server}]` : server}/`);
  const port = typeof node.port === "string" && /^\d+$/.test(node.port) ? Number(node.port) : node.port;
  if (typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65_535) throw new UserError("该节点端口无效。");
  return { hostname: url.hostname.replace(/^\[|\]$/g, ""), port };
}

async function deadline<T>(promise: Promise<T>, timeout: number, cancel?: () => void): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([promise, new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => { cancel?.(); reject(new ProbeTimeout()); }, timeout);
    })]);
  } finally { if (timer !== undefined) clearTimeout(timer); }
}

async function probe(name: string, node: Record<string, unknown> | undefined, options: PingOptions): Promise<PingResult> {
  if (!node) return { name, status: "unavailable", error: "该节点已不在最新源订阅中。" };
  if (!node.server) return { name, status: "unavailable", error: "该节点不支持 TCP 服务器测速。" };
  let address: { hostname: string; port: number };
  try { address = nodeAddress(node); }
  catch { return { name, status: "blocked", error: "节点地址或端口不合法，或指向内网和特殊用途地址。" }; }

  const dnsController = new AbortController();
  let socket: Socket | undefined;
  try {
    const answers = ipaddr.isValid(address.hostname) ? [address.hostname] : await deadline(
      (options.resolve ?? publicDns)(address.hostname, dnsController.signal),
      options.dnsTimeoutMs ?? 5_000,
      () => dnsController.abort(),
    );
    if (!answers.length) return { name, status: "unavailable", error: "节点域名无法解析。" };
    if (answers.some((answer) => !isPublicAddress(answer))) return { name, status: "blocked", error: "节点解析到内网或特殊用途地址，已拒绝测速。" };
    const hostname = answers.find((answer) => ipaddr.parse(answer).kind() === "ipv4") ?? answers[0];
    const started = performance.now();
    // Pin the validated public address so a second DNS lookup cannot rebind it.
    socket = options.connect({ hostname, port: address.port });
    void socket.closed?.catch(() => undefined);
    await deadline(socket.opened, options.socketTimeoutMs ?? 3_000);
    return { name, status: "ok", latencyMs: Math.round((performance.now() - started) * 10) / 10 };
  } catch (error) {
    return error instanceof ProbeTimeout
      ? { name, status: "timeout", error: "云端 TCP 连接或域名解析超时。" }
      : { name, status: "unavailable", error: "云端无法建立 TCP 连接；节点或云端网络可能不支持该连接。" };
  } finally {
    dnsController.abort();
    if (socket) {
      try { void Promise.resolve(socket.close()).catch(() => undefined); }
      catch { /* Closing an already failed socket can throw. */ }
    }
  }
}

export async function pingNodes(config: SourceConfig, names: string[], options: PingOptions) {
  if (!Array.isArray(names) || !names.length || names.length > 10 || new Set(names).size !== names.length || names.some((name) => typeof name !== "string" || !name.trim() || name.length > 256 || /[\r\n\0]/.test(name))) throw new UserError("每次请选择 1 至 10 个不同节点测速。");
  const indexed = new Map(config.proxies.map((node) => [node.name, node]));
  const results = new Array<PingResult>(names.length);
  let cursor = 0;
  await Promise.all(Array.from({ length: Math.min(4, names.length) }, async () => {
    while (cursor < names.length) {
      const index = cursor++;
      results[index] = await probe(names[index], indexed.get(names[index]), options);
    }
  }));
  return { results, measuredAt: new Date().toISOString() };
}
