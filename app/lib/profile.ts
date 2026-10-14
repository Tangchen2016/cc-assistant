import { stringify } from "yaml";
import type { Profile, Rule } from "./types.ts";
import type { SourceConfig } from "./source.ts";
import { validateSourceUrl } from "./source.ts";
import { UserError } from "./errors.ts";

const reserved = new Set(["DIRECT", "REJECT", "REJECT-DROP", "PASS", "GLOBAL", "COMPATIBLE"]);
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new UserError("配置格式无效。");
  return value as Record<string, unknown>;
}
function name(value: unknown, label: string, allowComma = false) {
  if (typeof value !== "string" || !value.trim() || value.length > 100 || /[\x00-\x1f\x7f\u0085\u2028\u2029]/.test(value) || !allowComma && value.includes(",")) throw new UserError(`${label}不能为空、超过 100 字符或包含${allowComma ? "控制字符" : "逗号及换行"}。`);
  return value.trim();
}

export function validateProfile(input: unknown): Profile {
  const value = object(input);
  const profileName = name(value.name, "配置名称", true);
  const sourceUrl = validateSourceUrl(value.sourceUrl).href;
  if (!Array.isArray(value.groups) || value.groups.length < 1 || value.groups.length > 10) throw new UserError("请添加 1 至 10 个自定义代理组。");
  const names = new Set<string>();
  const groups = value.groups.map((entry) => {
    const group = object(entry);
    const groupName = name(group.name, "代理组名称");
    if (reserved.has(groupName.toUpperCase()) || names.has(groupName)) throw new UserError("代理组名称重复或使用了保留名称。");
    names.add(groupName);
    if (!Array.isArray(group.nodes) || !group.nodes.length || group.nodes.length > 100) throw new UserError("每个代理组请选择 1 至 100 个具体节点。");
    const nodes = group.nodes.map((node) => {
      if (typeof node !== "string" || !node.trim() || node.length > 256 || /[\x00-\x1f\x7f\u0085\u2028\u2029]/.test(node) || reserved.has(node.toUpperCase())) throw new UserError("所选节点名称无效。");
      return node;
    });
    if (new Set(nodes).size !== nodes.length) throw new UserError("同一个代理组中不能重复选择节点。");
    let chain: { entry: string } | undefined;
    if (group.chain !== undefined) {
      const entry = object(group.chain).entry;
      if (typeof entry !== "string" || !entry.trim() || entry.length > 256 || /[\x00-\x1f\x7f\u0085\u2028\u2029]/.test(entry) || reserved.has(entry.toUpperCase())) throw new UserError("请选择有效的链式前置节点。");
      if (nodes.includes(entry)) throw new UserError("链式前置节点不能同时作为出口节点。");
      chain = { entry };
    }
    return { name: groupName, nodes, ...(chain ? { chain } : {}) };
  });
  if (!Array.isArray(value.rules) || value.rules.length > 100) throw new UserError("最多支持 100 条自定义规则。");
  const rules: Rule[] = value.rules.map((entry) => {
    const rule = object(entry);
    if (!["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD"].includes(String(rule.type))) throw new UserError("规则类型无效。");
    if (typeof rule.group !== "string" || !names.has(rule.group)) throw new UserError("规则必须指向当前配置中的自定义代理组。");
    if (typeof rule.value !== "string") throw new UserError("请填写规则域名或关键词。");
    const target = rule.value.trim().toLowerCase();
    if (!target || target.length > 253 || !/^[a-z0-9._-]+$/.test(target)) throw new UserError("规则仅支持域名或关键词，不能包含协议、逗号或换行。");
    if (rule.type !== "DOMAIN-KEYWORD" && target.split(".").some((part) => !part || part.length > 63 || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(part))) throw new UserError("规则域名格式无效。");
    return { type: rule.type as Rule["type"], value: target, group: rule.group };
  });
  return { name: profileName, sourceUrl, groups, rules };
}

export function transformSource(config: SourceConfig, input: Profile) {
  const profile = validateProfile(input);
  const nodeNames = new Set(config.proxies.map((node) => node.name));
  const sourceGroups = (config["proxy-groups"] ?? []) as Array<Record<string, unknown> & { name: string }>;
  const existingNames = new Set([...nodeNames, ...sourceGroups.map((group) => group.name)]);
  const warnings: string[] = [];
  const chained: SourceConfig["proxies"] = [];
  const allNames = new Set([...existingNames, ...profile.groups.map((group) => group.name)]);
  const proxiesByName = new Map(config.proxies.map((node) => [node.name, node]));
  const groups = profile.groups.map((group) => {
    if (existingNames.has(group.name)) throw new UserError(`自定义代理组「${group.name}」与源订阅的节点或代理组重名，请修改组名。`, 422);
    const required = [...group.nodes, ...(group.chain ? [group.chain.entry] : [])];
    const missing = required.filter((node) => !nodeNames.has(node));
    if (missing.length) warnings.push(`代理组「${group.name}」有 ${missing.length} 个已选节点从源订阅中消失，已设为 REJECT，请重新选择节点。`);
    const entries = missing.length ? ["REJECT"] : group.nodes.map((node, index) => {
      if (!group.chain) return node;
      const original = proxiesByName.get(node)!;
      if (original["dialer-proxy"] !== undefined) throw new UserError(`出口节点「${node}」已有链式前置，请选择其他出口以避免覆盖原链路。`, 422);
      // Clone only the exit, leaving original nodes and their other routes intact.
      const generated = `${group.name} · 链式出口 ${index + 1}`;
      if (allNames.has(generated)) throw new UserError("链式出口名称与源订阅重名，请修改自定义组名。", 422);
      allNames.add(generated);
      chained.push({ ...structuredClone(original), name: generated, "dialer-proxy": group.chain.entry });
      return generated;
    });
    if (!missing.length && group.chain) {
      const visited = new Set<string>(group.nodes);
      let current: string | undefined = group.chain.entry;
      while (current) {
        if (visited.has(current)) throw new UserError("链式代理包含循环，请更换前置节点。", 422);
        visited.add(current);
        const dependency: unknown = proxiesByName.get(current)?.["dialer-proxy"];
        if (dependency === undefined) break;
        if (typeof dependency !== "string" || !proxiesByName.has(dependency)) throw new UserError("前置节点依赖其他代理组或缺失节点，暂不支持作为固定链式前置。", 422);
        current = dependency;
      }
    }
    return { name: group.name, type: "select", proxies: entries };
  });
  const output = {
    ...config,
    mode: "rule",
    proxies: [...config.proxies, ...chained],
    "proxy-groups": [...sourceGroups, ...groups],
    rules: [...profile.rules.map((rule) => `${rule.type},${rule.value},${rule.group}`), ...(config.rules as string[] ?? [])],
  };
  const comment = warnings.map((warning) => `# ${warning}`).join("\n");
  return { yaml: `${comment ? `${comment}\n` : ""}${stringify(output, { lineWidth: 0 })}`, warnings };
}
