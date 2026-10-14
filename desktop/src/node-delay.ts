import { spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { request } from "node:http";
import { mkdtemp, chmod, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout as pause } from "node:timers/promises";
import ipaddr from "ipaddr.js";
import { stringify } from "yaml";
import type { SourceConfig } from "../../app/lib/source.ts";
import { isPublicAddress, validateSourceUrl } from "../../app/lib/source.ts";
import type { PingResult } from "../../app/lib/ping.ts";
import { UserError } from "../../app/lib/errors.ts";
import { localDns } from "./local-source.ts";

export const DELAY_TARGET = "https://www.gstatic.com/generate_204";
type Node = SourceConfig["proxies"][number];
type Options = {
  signal?: AbortSignal;
  chainEntry?: string;
  binaryPath?: string;
  resolve?: typeof localDns;
  bootTimeoutMs?: number;
  requestTimeoutMs?: number;
  tempRoot?: string;
};
const common = "name type server port udp tfo mptcp ip-version dialer-proxy";
const tls = "tls sni servername skip-cert-verify alpn client-fingerprint fingerprint name-cert-verify";
const transports = "network ws-opts grpc-opts h2-opts http-opts reality-opts";
const supported: Record<string, string> = {
  ss: "cipher password plugin plugin-opts udp-over-tcp udp-over-tcp-version",
  ssr: "cipher password obfs protocol obfs-param protocol-param",
  vmess: `${tls} ${transports} uuid alterId cipher packet-encoding global-padding authenticated-length`,
  vless: `${tls} ${transports} uuid flow packet-encoding`,
  trojan: `${tls} ${transports} password`,
  http: `${tls} username password headers`,
  socks5: `${tls} username password`,
  hysteria: `${tls} auth auth-str up down ports protocol obfs disable-mtu-discovery recv-window-conn recv-window`,
  hysteria2: `${tls} password obfs obfs-password up down ports hop-interval`,
  tuic: `${tls} uuid password token heartbeat-interval disable-sni reduce-rtt request-timeout udp-relay-mode congestion-controller max-udp-relay-packet-size fast-open max-open-streams`,
  snell: "psk version obfs-opts",
  anytls: `${tls} password idle-session-check-interval idle-session-timeout min-idle-session`,
};
const nested: Record<string, string> = {
  "ws-opts": "path headers max-early-data early-data-header-name v2ray-http-upgrade v2ray-http-upgrade-fast-open",
  "grpc-opts": "grpc-service-name",
  "h2-opts": "host path",
  "http-opts": "method path headers",
  "reality-opts": "public-key short-id",
  "obfs-opts": "mode host",
  "plugin-opts": "mode host path tls skip-cert-verify headers mux version password fingerprint obfs obfs-host obfs-uri",
};

function blocked(message: string): never { throw new UserError(message, 422); }
function scalar(value: unknown) {
  if (typeof value === "string") return value.length <= 4096 && !/[\x00\r\n]/.test(value);
  return typeof value === "boolean" || typeof value === "number" && Number.isFinite(value);
}
function values(value: unknown) {
  return scalar(value) || Array.isArray(value) && value.length <= 32 && value.every(scalar);
}
function headers(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).length > 32) return false;
  return Object.entries(value).every(([key, entry]) => /^[!#$%&'*+.^_`|~0-9a-z-]{1,100}$/i.test(key) && values(entry));
}

export function safeDelayNode(node: Node): Node {
  if (!Object.hasOwn(supported, node.type)) blocked("该节点协议暂不支持独立 HTTPS 测速。");
  if (["DIRECT", "REJECT", "GLOBAL", "PASS", "COMPATIBLE", "REJECT-DROP"].includes(node.name.toUpperCase())) blocked("该名称不是可测速的独立代理节点。");
  if (Buffer.byteLength(JSON.stringify(node)) > 32_768) blocked("该节点配置过大，已拒绝测速。");
  const allowed = new Set(`${common} ${supported[node.type]}`.split(" "));
  for (const [key, value] of Object.entries(node)) {
    if (!allowed.has(key)) blocked("节点包含暂不支持或不安全的配置项，已拒绝测速。");
    if (nested[key]) {
      if (!value || typeof value !== "object" || Array.isArray(value)) blocked("节点传输配置格式无效。");
      const keys = new Set(nested[key].split(" "));
      for (const [option, entry] of Object.entries(value)) {
        if (!keys.has(option) || !(option === "headers" ? headers(entry) : values(entry))) blocked("节点传输配置包含暂不支持或不安全的选项。");
      }
    } else if (key === "headers" ? !headers(value) : !values(value)) blocked("节点配置字段格式无效。");
  }
  if (node.plugin !== undefined && !["obfs", "v2ray-plugin", "shadow-tls", "restls"].includes(String(node.plugin))) blocked("该节点插件暂不支持独立测速。");
  if (node.network !== undefined && !["tcp", "ws", "http", "h2", "grpc"].includes(String(node.network))) blocked("该节点传输方式暂不支持独立测速。");
  if (node["dialer-proxy"] !== undefined && (typeof node["dialer-proxy"] !== "string" || !node["dialer-proxy"])) blocked("节点的前置代理配置无效。");
  if (typeof node.server !== "string" || /[\s/?#@%]/.test(node.server)) blocked("节点服务器地址无效。");
  const literal = ipaddr.isValid(node.server.replace(/^\[|\]$/g, ""));
  const host = node.server.replace(/^\[|\]$/g, "");
  validateSourceUrl(`https://${literal && host.includes(":") ? `[${host}]` : host}/`);
  const port = typeof node.port === "string" && /^\d+$/.test(node.port) ? Number(node.port) : node.port;
  if (!Number.isInteger(port) || Number(port) < 1 || Number(port) > 65_535) blocked("节点端口无效。");
  return structuredClone(node);
}

async function boundedDns(host: string, resolve: typeof localDns, signal: AbortSignal) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal.addEventListener("abort", abort, { once: true });
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    signal.throwIfAborted();
    return await Promise.race([
      resolve(host, controller.signal),
      new Promise<never>((_accept, reject) => { timer = setTimeout(() => { controller.abort(); reject(new Error("DNS timeout")); }, 5000); }),
      new Promise<never>((_accept, reject) => controller.signal.addEventListener("abort", () => reject(new Error("DNS canceled")), { once: true })),
    ]);
  } finally { if (timer) clearTimeout(timer); signal.removeEventListener("abort", abort); controller.abort(); }
}

export async function prepareDelayNodes(config: SourceConfig, names: string[], resolve: typeof localDns, signal: AbortSignal) {
  const indexed = new Map(config.proxies.map((node) => [node.name, node]));
  const safe = new Map<string, Node>();
  const verified = new Map<string, Promise<void>>();
  const results = new Map<string, PingResult>();
  const dependencies = async (name: string, stack: Set<string>): Promise<Node[]> => {
    if (stack.has(name) || stack.size > 10) blocked("节点前置代理循环或链路过长，已拒绝测速。");
    const raw = indexed.get(name);
    if (!raw) blocked("节点或前置代理已不在最新源订阅中，无法测速。");
    const node = safeDelayNode(raw);
    const host = String(node.server).replace(/^\[|\]$/g, "").replace(/\.$/, "");
    if (!verified.has(host)) verified.set(host, (async () => {
      const answers = ipaddr.isValid(host) ? [host] : await boundedDns(host, resolve, signal);
      if (!answers.length || answers.some((address) => !isPublicAddress(address))) blocked("节点解析到内网或特殊用途地址，已拒绝测速。");
    })());
    await verified.get(host);
    const next = new Set(stack).add(name);
    return node["dialer-proxy"] ? [...await dependencies(String(node["dialer-proxy"]), next), node] : [node];
  };
  let cursor = 0;
  await Promise.all(Array.from({ length: Math.min(4, names.length) }, async () => {
    while (cursor < names.length) {
      const name = names[cursor++];
      try { for (const node of await dependencies(name, new Set())) safe.set(node.name, node); }
      catch (error) {
        signal.throwIfAborted();
        results.set(name, { name, status: error instanceof UserError ? "blocked" : "unavailable", error: error instanceof UserError ? error.message : "节点域名无法解析，请稍后重试。" });
      }
    }
  }));
  return { nodes: [...safe.values()], valid: names.filter((name) => !results.has(name)), results };
}

function api(socketPath: string, secret: string, path: string, signal: AbortSignal, timeout: number) {
  return new Promise<{ status: number; data: Record<string, unknown> }>((accept, reject) => {
    signal.throwIfAborted();
    const call = request({ socketPath, path, method: "GET", headers: { Authorization: `Bearer ${secret}` }, signal }, (response) => {
      const chunks: Buffer[] = [];
      let size = 0;
      response.on("data", (chunk: Buffer) => {
        size += chunk.length;
        if (size > 8192) { call.destroy(new Error("large response")); return; }
        chunks.push(chunk);
      });
      response.on("error", reject);
      response.on("end", () => {
        try { accept({ status: response.statusCode ?? 500, data: JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown> }); }
        catch { reject(new Error("invalid response")); }
      });
    });
    const timer = setTimeout(() => call.destroy(new Error("request timeout")), timeout);
    call.on("error", reject); call.on("close", () => clearTimeout(timer)); call.end();
  });
}

export function isolatedDelayConfig(nodes: Node[], socketPath: string, secret: string) {
  return {
    port: 0, "socks-port": 0, "mixed-port": 0, "redir-port": 0, "tproxy-port": 0,
    "allow-lan": false, "bind-address": "127.0.0.1", mode: "rule", "log-level": "silent", ipv6: true,
    "external-controller": "", "external-controller-unix": socketPath, secret,
    "geo-auto-update": false, "find-process-mode": "off", "tcp-concurrent": true, "unified-delay": false,
    dns: { enable: false }, tun: { enable: false }, profile: { "store-selected": false, "store-fake-ip": false },
    proxies: nodes, "proxy-groups": [], rules: ["MATCH,REJECT"],
  };
}

async function stop(child: ChildProcess) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const closed = new Promise<void>((accept) => child.once("close", () => accept()));
  child.kill("SIGTERM");
  await Promise.race([closed, pause(500)]);
  if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); await Promise.race([closed, pause(500)]); }
}

const active = new Set<AbortController>();
export function cancelNodeDelays() { for (const controller of active) controller.abort(); }

export async function pingNodeDelay(config: SourceConfig, names: string[], options: Options = {}) {
  if (!names.length || names.length > 10 || new Set(names).size !== names.length || names.some((name) => typeof name !== "string" || !name.trim() || name.length > 256 || /[\x00\r\n]/.test(name))) throw new UserError("每次请选择 1 至 10 个不同节点测速。");
  const controller = new AbortController();
  const abort = () => controller.abort();
  options.signal?.addEventListener("abort", abort, { once: true });
  active.add(controller);
  let directory: string | undefined;
  let child: ChildProcess | undefined;
  try {
    options.signal?.throwIfAborted();
    let selectedConfig = config;
    const chainErrors = new Map<string, PingResult>();
    if (options.chainEntry !== undefined) {
      const entry = options.chainEntry;
      if (typeof entry !== "string" || !entry.trim() || entry.length > 256 || /[\x00-\x1f\x7f]/.test(entry)) throw new UserError("链式入口节点名称无效。");
      const entryExists = config.proxies.some(({ name }) => name === entry);
      const selected = new Set(names);
      selectedConfig = { ...config, proxies: config.proxies.map((node) => {
        if (!selected.has(node.name)) return node;
        if (!entryExists || node.name === entry || node["dialer-proxy"]) {
          chainErrors.set(node.name, { name: node.name, status: "blocked", error: !entryExists ? "入口节点已不在最新源订阅中。" : node.name === entry ? "入口和出口不能使用同一个节点。" : "该出口已有前置代理，无法覆盖原有链路测速。" });
          return node;
        }
        return { ...node, "dialer-proxy": entry };
      }) };
    }
    const prepared = await prepareDelayNodes(selectedConfig, names.filter((name) => !chainErrors.has(name)), options.resolve ?? localDns, controller.signal);
    const results = prepared.results;
    for (const [name, result] of chainErrors) results.set(name, result);
    const reply = () => ({ results: names.map((name) => results.get(name)!), measuredAt: new Date().toISOString(), method: "https" as const, target: DELAY_TARGET });
    if (!prepared.valid.length) return reply();
    const binary = options.binaryPath ?? process.env.DESKTOP_MIHOMO_PATH;
    if (!binary) {
      for (const name of prepared.valid) results.set(name, { name, status: "unavailable", error: "App 的独立测速内核不可用，请重新安装。" });
      return reply();
    }
    directory = await mkdtemp(join(options.tempRoot ?? "/tmp", "studio-delay-"));
    await chmod(directory, 0o700);
    const socketPath = join(directory, "control.sock");
    if (Buffer.byteLength(socketPath) > 100) throw new UserError("临时测速目录路径过长。", 500);
    const secret = randomBytes(32).toString("hex");
    const configPath = join(directory, "config.yaml");
    await writeFile(configPath, stringify(isolatedDelayConfig(prepared.nodes, socketPath, secret)), { mode: 0o600 });
    controller.signal.throwIfAborted();
    // No inherited CLASH_POST_UP/DOWN, override controller, config or proxy environment.
    child = spawn(binary, ["-d", directory, "-f", configPath], { cwd: directory, stdio: "ignore", env: { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", TMPDIR: directory, NODE_ENV: "production" } });
    let failed = false;
    child.on("error", () => { failed = true; });
    child.on("exit", () => { failed = true; });
    const onAbort = () => child?.kill("SIGTERM");
    controller.signal.addEventListener("abort", onAbort, { once: true });
    try {
      const deadline = Date.now() + (options.bootTimeoutMs ?? 5000);
      let ready = false;
      while (Date.now() < deadline && !failed) {
        controller.signal.throwIfAborted();
        try { ready = (await api(socketPath, secret, "/version", controller.signal, 300)).status === 200; }
        catch { controller.signal.throwIfAborted(); }
        if (ready) break;
        await pause(60, undefined, { signal: controller.signal });
      }
      if (!ready) throw new UserError("独立测速内核无法启动，该节点配置可能不受支持。", 502);
      try { await chmod(socketPath, 0o600); }
      catch (error) {
        // macOS may forbid chmod on AF_UNIX sockets; the owner-only parent protects it.
        if (!["EPERM", "EACCES"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error;
      }
      let cursor = 0;
      await Promise.all(Array.from({ length: Math.min(4, prepared.valid.length) }, async () => {
        while (cursor < prepared.valid.length) {
          const name = prepared.valid[cursor++];
          const path = `/proxies/${encodeURIComponent(name)}/delay?url=${encodeURIComponent(DELAY_TARGET)}&timeout=5000&expected=204`;
          try {
            const response = await api(socketPath, secret, path, controller.signal, options.requestTimeoutMs ?? 6500);
            const delay = response.data.delay;
            if (response.status === 200 && typeof delay === "number" && Number.isFinite(delay) && delay > 0 && delay <= 65_535) {
              // v1.19.24 can return a delay even when expected HTTP status mismatches.
              const state = await api(socketPath, secret, `/proxies/${encodeURIComponent(name)}`, controller.signal, 1000);
              const extra = state.data.extra as Record<string, { alive?: boolean; history?: { delay?: number }[] }> | undefined;
              const tested = extra?.[DELAY_TARGET];
              if (state.status === 200 && tested?.alive === true && tested.history?.at(-1)?.delay === delay) results.set(name, { name, status: "ok", latencyMs: delay });
              else results.set(name, { name, status: "unavailable", error: "节点未获得测速目标的预期 HTTPS 204 响应。" });
            }
            else results.set(name, { name, status: response.status === 504 ? "timeout" : "unavailable", error: response.status === 504 ? "节点 HTTPS 请求超时。" : "该节点无法完成 HTTPS 测速，请检查节点或稍后重试。" });
          } catch {
            controller.signal.throwIfAborted();
            results.set(name, { name, status: "timeout", error: "节点 HTTPS 请求超时。" });
          }
        }
      }));
    } catch (error) {
      controller.signal.throwIfAborted();
      for (const name of prepared.valid) if (!results.has(name)) results.set(name, { name, status: "unavailable", error: error instanceof UserError ? error.message : "独立 HTTPS 测速暂时不可用。" });
    } finally { controller.signal.removeEventListener("abort", onAbort); }
    return reply();
  } finally {
    options.signal?.removeEventListener("abort", abort); active.delete(controller); controller.abort();
    if (child) await stop(child);
    if (directory) await rm(directory, { recursive: true, force: true });
  }
}
