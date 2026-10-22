import type { Profile, Group, Rule } from "./types.ts";
import type { SourceConfig } from "./source.ts";
import { validateProfile } from "./profile.ts";
import { AUTO_CHAIN_ENTRY, parseFixedExitLink } from "./fixed-exit.ts";
import { autoFrontNodes } from "./profile.ts";
import { validateSourceUrl } from "./source-validation.ts";
import { UserError } from "./errors.ts";
import { allowedClaudeRule } from "./claude-rules.ts";

export type MobileExport = "shadowrocket-nodes" | "shadowrocket-module";
const claudeRule = (rule: Rule) => allowedClaudeRule(rule);
function b64(value: string) { return btoa(String.fromCharCode(...new TextEncoder().encode(value))); }
function line(value: string) { return value.replace(/[\x00-\x1f\x7f\u0085\u2028\u2029]/g, " "); }
function fail(message: string): never { throw new UserError(`小火箭导出：${message}`, 422); }
function field(value: unknown, label: string) {
  if (typeof value !== "string" || !value || value.length > 4096 || /[\x00-\x1f\x7f\u0085\u2028\u2029]/.test(value)) return fail(`${label}无效。`);
  return value;
}
function hostAndPort(node: Record<string, unknown>) {
  const server = field(node.server, "节点地址");
  const host = server.includes(":") && !server.startsWith("[") ? `[${server}]` : server;
  const checked = validateSourceUrl(`https://${host}`);
  if (checked.port || checked.pathname !== "/" || /[\s/@?#\\]/.test(server)) fail("节点地址必须是公共主机名或 IP。");
  const port = node.port;
  if (typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65535) fail("节点端口无效。");
  return { host, port };
}
function websocket(node: Record<string, unknown>, params: URLSearchParams) {
  const network = node.network ?? "tcp";
  if (network === "tcp") return;
  if (network !== "ws") fail("目前只支持 TCP 或 WebSocket 节点，请为手机选择兼容节点。");
  const ws = node["ws-opts"] as Record<string, unknown> | undefined;
  if (!ws || typeof ws !== "object" || Array.isArray(ws) || Object.keys(ws).some(k => !["path", "headers"].includes(k))) fail("WebSocket 参数暂不支持。");
  const headers = ws.headers as Record<string, unknown> | undefined;
  if (headers && (typeof headers !== "object" || Array.isArray(headers) || Object.keys(headers).some(k => k.toLowerCase() !== "host"))) fail("暂不支持自定义 WebSocket 标头。");
  params.set("obfs", "websocket");
  params.set("path", field(ws.path ?? "/", "WebSocket 路径"));
  const host = headers && Object.entries(headers).find(([k]) => k.toLowerCase() === "host")?.[1];
  if (host !== undefined) params.set("obfsParam", field(host, "WebSocket Host"));
}
function nodeURI(node: Record<string, unknown>, name: string, chain?: string) {
  if (node["dialer-proxy"] !== undefined || node.plugin !== undefined || node["plugin-opts"] !== undefined || node["reality-opts"] !== undefined || node.smux !== undefined || node.flow || node["packet-encoding"] || node["skip-cert-verify"]) fail("节点含尚不支持的插件、已有代理链或 TLS 扩展，请选择兼容节点。");
  const { host, port } = hostAndPort(node);
  const params = new URLSearchParams();
  if (chain) params.set("chain", chain);
  let uri: string;
  if (node.type === "ss") {
    const cipher = field(node.cipher, "加密方式");
    const password = field(node.password, "节点凭据");
    uri = `ss://${b64(`${cipher}:${password}`)}@${host}:${port}`;
  } else if (node.type === "vless" || node.type === "vmess") {
    const uuid = field(node.uuid, "节点 UUID");
    if (!/^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i.test(uuid)) fail("节点 UUID 无效。");
    if (node.type === "vless" && node.tls !== true) fail("VLESS 出口需要启用 TLS。");
    params.set("tls", node.tls === true ? "1" : "0");
    if (node.servername) params.set("peer", field(node.servername, "TLS 主机名"));
    if (node.type === "vmess") {
      const alterId = node.alterId ?? 0;
      if (typeof alterId !== "number" || !Number.isInteger(alterId) || alterId < 0) fail("VMess 参数无效。");
      params.set("alterId", String(alterId));
    }
    websocket(node, params);
    const method = node.type === "vless" ? "none" : field(node.cipher ?? "auto", "加密方式");
    uri = `${node.type}://${b64(`${method}:${uuid}@${host}:${port}`)}`;
  } else if (node.type === "trojan") {
    const password = field(node.password, "节点凭据");
    params.set("tls", "1");
    if (node.sni) params.set("peer", field(node.sni, "TLS 主机名"));
    websocket(node, params);
    uri = `trojan://${encodeURIComponent(password)}@${host}:${port}`;
  } else return fail("当前所选节点协议暂不支持手机导出，支持 SS、VMess、VLESS 和 Trojan。");
  return `${uri}${params.size ? `?${params}` : ""}#${encodeURIComponent(name)}`;
}
function firstEntry(config: SourceConfig, name: string): Record<string, unknown> {
  const visiting = new Set<string>();
  const visit = (target: string): Record<string, unknown> | undefined => {
    if (["DIRECT", "REJECT", "REJECT-DROP"].includes(target)) return undefined;
    if (visiting.has(target)) fail("前置存在循环依赖。");
    if (visiting.size >= 64) fail("前置分组层级过深，请选择明确节点。");
    const node = config.proxies.find(n => n.name === target);
    if (node) return node;
    const group = (config["proxy-groups"] as Array<Record<string, unknown>> | undefined)?.find(g => g.name === target);
    if (!group || !Array.isArray(group.proxies) || group.use || group["include-all"] || group["include-all-proxies"] || group["include-all-providers"]) fail("前置节点缺失或分组动态，不能安全导出。");
    visiting.add(target);
    for (const item of group.proxies) {
      if (typeof item !== "string") fail("前置分组无效。");
      const found = visit(item);
      if (found) { visiting.delete(target); return found; }
    }
    visiting.delete(target);
    return undefined;
  };
  return visit(name) ?? fail("前置分组没有明确节点。");
}
export function renderShadowrocket(config: SourceConfig, input: Profile, identity: string, format: MobileExport) {
  if (!/^[a-f0-9]{32}$/.test(identity)) fail("配置标识无效。");
  const profile = validateProfile(input);
  const rules = profile.rules.filter(claudeRule);
  if (!rules.length) fail("当前配置没有 Claude 域名规则。");
  const aliases = new Map<Group, string>();
  const uris: string[] = [];
  profile.groups.forEach((group, index) => {
    if (!rules.some(rule => rule.group === group.name)) return;
    const alias = `CC-Claude-${identity}-${index + 1}`;
    aliases.set(group, alias);
    let entry: string | undefined;
    if (group.chain && group.chain.entry !== "DIRECT") {
      entry = `CC-Entry-${identity}-${index + 1}`;
      // Shadowrocket has no url-test chain front; the automatic front exports its first candidate.
      const front = group.chain.entry === AUTO_CHAIN_ENTRY ? autoFrontNodes(config)[0] ?? fail("源订阅中没有可用前置节点。") : group.chain.entry;
      uris.push(nodeURI(firstEntry(config, front), entry));
    }
    if (group.fixedExit) {
      // Validate supported security/transport first; preserve the original share-link parameters.
      parseFixedExitLink(group.fixedExit);
      const url = new URL(group.fixedExit);
      url.hash = alias;
      if (entry) url.searchParams.set("chain", entry);
      uris.push(url.href);
    } else {
      const selected = config.proxies.find(n => n.name === group.nodes[0]);
      if (!selected) fail("所选出口已从源订阅移除，请重新选择。");
      uris.push(nodeURI(selected, alias, entry));
    }
  });
  const title = `${profile.name} · Claude ${format === "shadowrocket-nodes" ? "节点" : "规则"}`;
  if (format === "shadowrocket-nodes") return { text: b64(uris.join("\n")), title, extension: "txt" };
  const rows = [`#!name=${line(title)}`, "#!desc=仅扩展 Claude 域名，不修改现有网站分流、DNS 或兜底策略。", "# 请先添加对应的 Claude 专用节点订阅，再启用本模块。", profile.client === "shadowrocket" ? "# 需要链式代理时，在小火箭固定出口节点的代理通过中选择已有普通节点，勿选择出口自身。" : "# 每组使用首个已选出口；链式前置分组展开后使用首个明确节点。", "[Rule]"];
  for (const rule of rules) {
    const group = profile.groups.find(g => g.name === rule.group)!;
    const alias = aliases.get(group)!;
    if (group.fixedExit || group.chain) rows.push(`AND,((${rule.type},${rule.value}),(PROTOCOL,UDP)),REJECT-NO-DROP`);
    rows.push(`${rule.type},${rule.value},${alias}`);
  }
  return { text: rows.join("\n") + "\n", title, extension: "module" };
}
