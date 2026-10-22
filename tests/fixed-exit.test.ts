import assert from "node:assert/strict";
import test from "node:test";
import { parse } from "yaml";
import { parseFixedExitLink } from "../app/lib/fixed-exit.ts";
import { transformSource, validateProfile } from "../app/lib/profile.ts";
import { validateDraft } from "../desktop/src/local-store.ts";
import type { Profile } from "../app/lib/types.ts";
import type { SourceConfig } from "../app/lib/source.ts";
const link = "vless://11111111-2222-4333-8444-555555555555@node.example.com:443?encryption=none&security=tls&type=ws&sni=node.example.com&host=node.example.com&path=%2Fsocket#Synthetic";
const profile: Profile = { name: "Fixed exit", sourceUrl: "https://example.com/sub", groups: [{ name: "Claude", nodes: [], fixedExit: link, chain: { entry: "General" } }], rules: [{ type: "DOMAIN-SUFFIX", value: "claude.ai", group: "Claude" }] };
const source: SourceConfig = { proxies: [{ name: "HK", type: "ss" }, { name: "JP", type: "ss" }], "proxy-groups": [{ name: "General", type: "select", proxies: ["HK", "JP", "DIRECT"] }], rules: ["MATCH,General"] };

test("fixed exit follows original group selection and preserves every upstream route", () => {
  const before = structuredClone(source);
  const output = parse(transformSource(source, profile).yaml);
  assert.deepEqual(source, before);
  assert.deepEqual(output.proxies.slice(0, 2), source.proxies);
  assert.deepEqual(output["proxy-groups"][0], (source["proxy-groups"] as unknown[])[0]);
  assert.equal(output.proxies[2]["dialer-proxy"], "General");
  assert.equal(output.proxies[2].server, "node.example.com");
  assert.deepEqual(output["proxy-groups"][1].proxies, [output.proxies[2].name]);
  assert.deepEqual(output.rules, ["AND,((DOMAIN-SUFFIX,claude.ai),(NETWORK,UDP)),REJECT", "DOMAIN-SUFFIX,claude.ai,Claude", "MATCH,General"]);
});

test("missing front or missing nested node fails closed while profile retains fixed exit", () => {
  for (const config of [{ ...source, "proxy-groups": [] }, { ...source, proxies: source.proxies.slice(0, 1) }]) {
    const result = transformSource(config, profile);
    assert.deepEqual(parse(result.yaml)["proxy-groups"].at(-1).proxies, ["REJECT"]);
    assert.equal(result.warnings.length, 1);
    assert.equal(validateProfile(profile).groups[0].fixedExit, link);
  }
});

test("nested group and node cycles cannot turn fixed exit into a recursive chain", () => {
  for (const config of [
    { ...source, proxies: [{ name: "HK", type: "ss", "dialer-proxy": "General" }, source.proxies[1]] },
    { ...source, "proxy-groups": [{ name: "General", type: "select", proxies: ["Claude"] }] },
    { ...source, "proxy-groups": [{ name: "General", type: "select", proxies: ["Nested"] }, { name: "Nested", type: "select", proxies: ["General"] }] },
  ]) assert.throws(() => transformSource(config, profile), /循环/);
});

test("direct front is explicit and still always leaves through fixed exit", () => {
  for (const chain of [undefined, { entry: "DIRECT" }]) {
    const output = parse(transformSource(source, { ...profile, groups: [{ ...profile.groups[0], chain }] }).yaml);
    assert.deepEqual(output["proxy-groups"].at(-1).proxies, ["Claude · 固定出口"]);
    assert.equal(output.proxies.at(-1)["dialer-proxy"], chain?.entry);
  }
});

test("draft preserves incomplete fixed-exit input; runnable profiles reject it", () => {
  const draft = { ...profile, groups: [{ ...profile.groups[0], fixedExit: "" }] };
  assert.equal(validateDraft(draft).groups[0].fixedExit, "");
  assert.throws(() => validateProfile(draft));
  assert.equal(validateDraft(profile).groups[0].fixedExit, link);
});

test("unsafe or unsupported links are rejected without disclosing credentials", () => {
  for (const bad of [link.replace("node.example.com", "127.0.0.1"), link.replace("type=ws", "type=tcp"), link.replace("security=tls", "security=none"), link.replace("11111111-2222-4333-8444-555555555555", "SECRET"), link.replace("#Synthetic", "&allowInsecure=1"), link.replace("#Synthetic", "&host=localhost"), link.replace("%2Fsocket", "%2F%0D%0AInjected")]) {
    assert.throws(() => parseFixedExitLink(bad), (error: unknown) => error instanceof Error && !error.message.includes("SECRET") && !error.message.includes("vless://"));
  }
  assert.equal(parseFixedExitLink(link)["ws-opts"].path, "/socket");
});


test("UDP guards cover fixed exit match types without affecting ordinary groups or source rules", () => {
  const input: Profile = { ...profile, groups: [...profile.groups, { name: "Ordinary", nodes: ["HK"] }], rules: [
    { type: "DOMAIN", value: "api.anthropic.com", group: "Claude" },
    { type: "DOMAIN-SUFFIX", value: "claude.ai", group: "Claude" },
    { type: "DOMAIN-KEYWORD", value: "claude", group: "Claude" },
    { type: "DOMAIN-SUFFIX", value: "example.com", group: "Ordinary" },
  ] };
  const rules = parse(transformSource(source, input).yaml).rules;
  assert.deepEqual(rules, [
    "AND,((DOMAIN,api.anthropic.com),(NETWORK,UDP)),REJECT",
    "DOMAIN,api.anthropic.com,Claude",
    "AND,((DOMAIN-SUFFIX,claude.ai),(NETWORK,UDP)),REJECT",
    "DOMAIN-SUFFIX,claude.ai,Claude",
    "AND,((DOMAIN-KEYWORD,claude),(NETWORK,UDP)),REJECT",
    "DOMAIN-KEYWORD,claude,Claude",
    "DOMAIN-SUFFIX,example.com,Ordinary",
    "MATCH,General",
  ]);
});

test("automatic front url-tests every source node, independent of selected group", () => {
  const withInfo = { ...source, proxies: [{ name: "剩余流量：10GB", type: "ss" }, ...source.proxies, { name: "Chained", type: "ss", "dialer-proxy": "HK" }] };
  const output = parse(transformSource(withInfo, { ...profile, groups: [{ ...profile.groups[0], chain: { entry: "*" } }] }).yaml);
  const hop = output["proxy-groups"].at(-1);
  assert.deepEqual(hop, { name: "Claude · 前置跳板", type: "url-test", proxies: ["HK", "JP"], url: "https://www.gstatic.com/generate_204", interval: 300, tolerance: 50 });
  assert.equal(output.proxies.at(-1)["dialer-proxy"], hop.name);
  assert.deepEqual(output.rules.slice(0, 2), ["AND,((DOMAIN-SUFFIX,claude.ai),(NETWORK,UDP)),REJECT", "DOMAIN-SUFFIX,claude.ai,Claude"]);
  assert.throws(() => validateProfile({ ...profile, groups: [{ name: "Claude", nodes: ["HK"], chain: { entry: "*" } }] }), /前置/);
});
