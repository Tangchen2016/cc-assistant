import ipaddr from "ipaddr.js";
import { parseDocument } from "yaml";
import { UserError } from "./errors.ts";
import { sourceName } from "./subscription-name.ts";

export type SourceConfig = Record<string, unknown> & {
  proxies: Array<Record<string, unknown> & { name: string; type: string }>;
};
type SourceOptions = {
  fetch?: typeof globalThis.fetch;
  resolve?: (hostname: string, signal: AbortSignal) => Promise<string[]>;
};
const MAX_SOURCE = 2 * 1024 * 1024;

export function isPublicAddress(address: string) {
  try { return ipaddr.process(address).range() === "unicast"; }
  catch { return false; }
}

export function validateSourceUrl(value: unknown) {
  if (typeof value !== "string" || value.length > 4096) throw new UserError("请输入有效的源订阅地址。");
  let url: URL;
  try { url = new URL(value); } catch { throw new UserError("请输入完整的 HTTP / HTTPS 订阅地址。"); }
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.hash) {
    throw new UserError("仅支持不含账号密码和片段的 HTTP / HTTPS 订阅地址。");
  }
  const host = url.hostname.replace(/^\[|\]$/g, "").toLowerCase().replace(/\.$/, "");
  if (!host || host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal") || !host.includes("." ) && !host.includes(":")) {
    throw new UserError("订阅地址必须指向公共网络。");
  }
  if (ipaddr.isValid(host) && !isPublicAddress(host)) throw new UserError("禁止访问本机、内网或特殊用途地址。");
  return url;
}

export async function publicDns(hostname: string, signal: AbortSignal, fetcher: typeof fetch = globalThis.fetch) {
  const answers = await Promise.all(["A", "AAAA"].map(async (type) => {
    const response = await fetcher(`https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(hostname)}&type=${type}`, {
      headers: { Accept: "application/dns-json" }, signal, redirect: "manual", cache: "no-store",
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new UserError("无法校验订阅地址的 DNS，请稍后重试。", 502);
    }
    const body = await response.json() as { Status?: number; Answer?: { type: number; data: string }[] };
    if (body.Status !== 0) throw new UserError("源订阅域名无法解析。", 502);
    return (body.Answer ?? []).filter((entry) => entry.type === 1 || entry.type === 28).map((entry) => entry.data);
  }));
  return answers.flat();
}

function verifyTree(value: unknown, seen = new Set<object>(), depth = 0) {
  if (depth > 64) throw new UserError("源订阅结构嵌套过深。", 422);
  if (typeof value !== "object" || value === null) return;
  if (seen.has(value)) throw new UserError("源订阅不支持循环 YAML 别名。", 422);
  seen.add(value);
  for (const [key, child] of Object.entries(value)) {
    if (["__proto__", "prototype", "constructor"].includes(key)) throw new UserError("源订阅包含不安全的字段。", 422);
    verifyTree(child, seen, depth + 1);
  }
  seen.delete(value);
}

export function parseSource(text: string): SourceConfig {
  if (new TextEncoder().encode(text).length > MAX_SOURCE) throw new UserError("源订阅超过 2 MiB 限制。", 413);
  let config: unknown;
  try {
    const document = parseDocument(text, { uniqueKeys: true, schema: "core" });
    if (document.errors.length) throw new Error("invalid YAML");
    config = document.toJS({ maxAliasCount: 100 });
  } catch { throw new UserError("源订阅不是有效的 Clash / Mihomo YAML；暂不支持 Base64 或节点链接列表。", 422); }
  verifyTree(config);
  if (!config || typeof config !== "object" || Array.isArray(config)) throw new UserError("源订阅必须为 Clash / Mihomo 配置。", 422);
  const record = config as Record<string, unknown>;
  if (!Array.isArray(record.proxies) || !record.proxies.length) throw new UserError("源订阅没有内嵌 proxies 节点；暂不支持仅 proxy-providers 的配置。", 422);
  if (record.proxies.length > 5000) throw new UserError("源订阅节点过多，最多支持 5000 个。", 422);
  const names = new Set<string>();
  for (const proxy of record.proxies) {
    if (!proxy || typeof proxy !== "object" || typeof proxy.name !== "string" || typeof proxy.type !== "string" || !proxy.name.trim() || proxy.name.length > 256 || /[\r\n\0]/.test(proxy.name)) {
      throw new UserError("源订阅存在无效节点。", 422);
    }
    if (names.has(proxy.name)) throw new UserError("源订阅存在重名节点，请在源订阅中修正。", 422);
    names.add(proxy.name);
  }
  if (record["proxy-groups"] !== undefined && (!Array.isArray(record["proxy-groups"]) || record["proxy-groups"].some((group) => !group || typeof group !== "object" || typeof group.name !== "string"))) {
    throw new UserError("源订阅的代理组格式无效。", 422);
  }
  if (record.rules !== undefined && (!Array.isArray(record.rules) || record.rules.some((rule) => typeof rule !== "string"))) throw new UserError("源订阅的规则格式无效。", 422);
  return record as SourceConfig;
}

export async function fetchSource(sourceUrl: string, options: SourceOptions = {}) {
  const fetcher = options.fetch ?? (await import("../../server/public-fetch.ts")).publicFetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15_000);
  try {
    let url = validateSourceUrl(sourceUrl);
    for (let hop = 0; hop <= 5; hop++) {
      const host = url.hostname.replace(/^\[|\]$/g, "").replace(/\.$/, "");
      const addresses = ipaddr.isValid(host) ? [host] : await (options.resolve ? options.resolve(host, controller.signal) : publicDns(host, controller.signal, fetcher));
      if (!addresses.length || addresses.some((address) => !isPublicAddress(address))) throw new UserError("订阅域名解析到内网或特殊用途地址，已拒绝请求。", 422);
      const response = await fetcher(url.href, {
        redirect: "manual", signal: controller.signal, cache: "no-store",
        headers: { "User-Agent": "clash.meta/subscription-enhancer", Accept: "application/yaml,text/yaml,text/plain,*/*", "Cache-Control": "no-cache" },
      });
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get("Location");
        await response.body?.cancel();
        if (!location || hop === 5) throw new UserError("源订阅重定向过多或无效。", 502);
        url = validateSourceUrl(new URL(location, url).href);
        continue;
      }
      if (!response.ok) {
        await response.body?.cancel();
        if (response.status === 403 && response.headers.get("cf-mitigated") === "challenge") throw new UserError("源订阅触发 Cloudflare 浏览器验证，云端无法直接读取（HTTP 403）。请使用免验证订阅接口，或联系订阅服务商放行 Worker 请求。", 502);
        if (response.status === 403) throw new UserError("源站拒绝云端请求（HTTP 403），请检查源站访问限制或订阅权限。", 502);
        throw new UserError(`源订阅返回 HTTP ${response.status}，请检查订阅是否有效。`, 502);
      }
      const reader = response.body?.getReader();
      if (!reader) throw new UserError("源订阅内容为空。", 502);
      const chunks: Uint8Array[] = [];
      let size = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > MAX_SOURCE) { await reader.cancel(); throw new UserError("源订阅超过 2 MiB 限制。", 413); }
          chunks.push(value);
        }
      } finally { reader.releaseLock(); }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      const metadata = response.headers.get("Subscription-Userinfo");
      const userInfo = metadata && metadata.length <= 256 && /^(?:upload|download|total|expire)=\d+(?:\s*;\s*(?:upload|download|total|expire)=\d+)*\s*$/.test(metadata) ? metadata : undefined;
      return { config: parseSource(new TextDecoder().decode(bytes)), fetchedAt: new Date().toISOString(), userInfo, sourceName: sourceName(response.headers, sourceUrl) };
    }
    throw new UserError("源订阅重定向无效。", 502);
  } catch (error) {
    if (error instanceof UserError) throw error;
    throw new UserError(controller.signal.aborted ? "拉取源订阅超时，请稍后重试。" : "无法连接源订阅，请检查地址和源站状态。", 502);
  } finally { clearTimeout(timer); }
}
