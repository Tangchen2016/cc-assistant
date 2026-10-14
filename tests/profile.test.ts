import assert from "node:assert/strict";
import test from "node:test";
import { parse, stringify } from "yaml";
import { transformSource, validateProfile } from "../app/lib/profile.ts";
import { fetchSource, parseSource } from "../app/lib/source.ts";
import type { Profile } from "../app/lib/types.ts";

function profile(): Profile {
  return {
    name: "Claude independent route",
    sourceUrl: "https://subscription.example.net/clash?token=synthetic",
    groups: [{ name: "Claude fixed", nodes: ["US fixed"] }],
    rules: [
      { type: "DOMAIN-SUFFIX", value: "anthropic.com", group: "Claude fixed" },
      { type: "DOMAIN-SUFFIX", value: "claude.ai", group: "Claude fixed" },
      { type: "DOMAIN-SUFFIX", value: "claude.com", group: "Claude fixed" },
    ],
  };
}

function source(password = "first-secret") {
  return parseSource(stringify({
    mode: "global",
    "mixed-port": 7890,
    "allow-lan": false,
    dns: { enable: true, nameserver: ["https://1.1.1.1/dns-query"] },
    tun: { enable: true, stack: "mixed" },
    "rule-providers": { example: { type: "http", behavior: "domain", url: "https://rules.example.net/domains.yaml" } },
    proxies: [
      { name: "US fixed", type: "ss", server: "proxy.example.net", port: 443, cipher: "aes-128-gcm", password },
      { name: "Other node", type: "ss", server: "other.example.net", port: 443, cipher: "aes-128-gcm", password: "other-secret" },
    ],
    "proxy-groups": [{ name: "General", type: "select", proxies: ["Other node", "DIRECT"] }],
    rules: ["DOMAIN-SUFFIX,anthropic.com,General", "MATCH,General"],
  }));
}

test("custom Claude rules precede original rules and only custom group points to pinned node", () => {
  const result = transformSource(source(), profile());
  const output = parse(result.yaml);
  assert.deepEqual(output.rules, [
    "DOMAIN-SUFFIX,anthropic.com,Claude fixed",
    "DOMAIN-SUFFIX,claude.ai,Claude fixed",
    "DOMAIN-SUFFIX,claude.com,Claude fixed",
    "DOMAIN-SUFFIX,anthropic.com,General",
    "MATCH,General",
  ]);
  assert.deepEqual(output["proxy-groups"], [
    { name: "General", type: "select", proxies: ["Other node", "DIRECT"] },
    { name: "Claude fixed", type: "select", proxies: ["US fixed"] },
  ]);
  assert.equal(output.mode, "rule");
  assert.equal(result.warnings.length, 0);
});

test("original nodes, credentials, DNS, TUN, providers and ports survive without input mutation", () => {
  const original = source();
  const before = structuredClone(original);
  const output = parse(transformSource(original, profile()).yaml);
  for (const key of ["proxies", "dns", "tun", "rule-providers", "mixed-port", "allow-lan"]) {
    assert.deepEqual(output[key], original[key], key);
  }
  assert.deepEqual(original, before);
});

test("generated subscriptions reflect new upstream credentials on every request", async () => {
  let calls = 0;
  const fakeFetch: typeof fetch = async () => new Response(stringify(source(`fresh-${++calls}`)));
  const download = async () => {
    const latest = await fetchSource(profile().sourceUrl, { fetch: fakeFetch, resolve: async () => ["8.8.8.8"] });
    return parse(transformSource(latest.config, profile()).yaml);
  };
  const first = await download();
  const second = await download();
  assert.equal(calls, 2);
  assert.equal(first.proxies[0].password, "fresh-1");
  assert.equal(second.proxies[0].password, "fresh-2");
  assert.deepEqual(first["proxy-groups"], second["proxy-groups"]);
  assert.deepEqual(first.rules, second.rules);
});

test("missing pinned node fails closed; no fallback to other available or general group", () => {
  const current = source();
  current.proxies = current.proxies.filter((node) => node.name !== "US fixed");
  const result = transformSource(current, profile());
  const output = parse(result.yaml);
  assert.deepEqual(output["proxy-groups"].at(-1).proxies, ["REJECT"]);
  assert.equal(result.warnings.length, 1);
  assert.match(result.warnings[0], /消失/);
  assert.equal(output.rules[0], "DOMAIN-SUFFIX,anthropic.com,Claude fixed");
});

test("partially missing multi-node selection also rejects instead of silently choosing remaining node", () => {
  const input = profile();
  input.groups[0].nodes.push("Removed node");
  const output = parse(transformSource(source(), input).yaml);
  assert.deepEqual(output["proxy-groups"].at(-1).proxies, ["REJECT"]);
});

test("source update collision with custom group is rejected rather than overwritten", () => {
  for (const collision of ["General", "US fixed"]) {
    const input = profile();
    input.groups[0].name = collision;
    input.rules = [];
    assert.throws(() => transformSource(source(), input), /重名/);
  }
});

test("groups cannot use reserved targets, repeat names/nodes, or refer to general groups as nodes", () => {
  const invalidGroups = [
    [{ name: "DIRECT", nodes: ["US fixed"] }],
    [{ name: "reject", nodes: ["US fixed"] }],
    [{ name: "GLOBAL", nodes: ["US fixed"] }],
    [{ name: "Claude fixed", nodes: ["DIRECT"] }],
    [{ name: "Claude fixed", nodes: ["US fixed", "US fixed"] }],
    [{ name: "Claude fixed", nodes: [] }],
    [{ name: "Duplicate", nodes: ["US fixed"] }, { name: "Duplicate", nodes: ["Other node"] }],
  ];
  for (const groups of invalidGroups) assert.throws(() => validateProfile({ ...profile(), groups, rules: [] }));
  const input = profile();
  input.groups[0].nodes = ["General"];
  assert.deepEqual(parse(transformSource(source(), input).yaml)["proxy-groups"].at(-1).proxies, ["REJECT"]);
});

test("rule grammar injection and invalid domain labels are rejected", () => {
  for (const value of ["anthropic.com,DIRECT", "anthropic.com\nMATCH,DIRECT", "https://claude.ai", "*.claude.ai", ".claude.ai", "claude..ai", "-claude.ai", "claude-.ai", "a".repeat(64) + ".com"]) {
    const input = profile();
    input.rules[0].value = value;
    assert.throws(() => validateProfile(input), Error, value);
  }
  for (const name of ["Injected,MATCH", "Injected\nMATCH", "Injected\0"]) {
    const input = profile();
    input.groups[0].name = name;
    input.rules = [];
    assert.throws(() => validateProfile(input));
  }
});

test("unknown group references/types and oversized structures are rejected", () => {
  const input = profile();
  assert.throws(() => validateProfile({ ...input, rules: [{ type: "DOMAIN-SUFFIX", value: "claude.ai", group: "General" }] }));
  assert.throws(() => validateProfile({ ...input, rules: [{ type: "MATCH", value: "claude.ai", group: "Claude fixed" }] }));
  assert.throws(() => validateProfile({ ...input, groups: Array.from({ length: 11 }, (_, i) => ({ name: `Group ${i}`, nodes: ["US fixed"] })) }));
  assert.throws(() => validateProfile({ ...input, rules: Array.from({ length: 101 }, () => input.rules[0]) }));
  for (const value of [null, [], "bad", { name: "Only name" }]) assert.throws(() => validateProfile(value));
});

test("changing a saved configuration's source URL cannot bypass the source boundary", () => {
  for (const sourceUrl of ["http://127.0.0.1/private", "http://169.254.169.254/metadata", "http://[::1]/private", "file:///etc/passwd", "https://user:pass@example.net/subscription"]) {
    assert.throws(() => validateProfile({ ...profile(), sourceUrl }));
  }
});

test("airport display name may contain commas while proxy group grammar still rejects them", () => {
  assert.equal(validateProfile({ ...profile(), name: "增强-Foo, Bar" }).name, "增强-Foo, Bar");
  assert.throws(() => validateProfile({ ...profile(), groups: [{ name: "Foo, Bar", nodes: ["US fixed"] }], rules: [] }));
});

test("valid exact-domain and keyword rules serialize without adding implicit fallback", () => {
  const input = profile();
  input.rules = [
    { type: "DOMAIN", value: "API.Anthropic.COM", group: "Claude fixed" },
    { type: "DOMAIN-KEYWORD", value: "Anthropic", group: "Claude fixed" },
  ];
  const output = parse(transformSource(source(), input).yaml);
  assert.deepEqual(output.rules.slice(0, 2), ["DOMAIN,api.anthropic.com,Claude fixed", "DOMAIN-KEYWORD,anthropic,Claude fixed"]);
  assert.deepEqual(output["proxy-groups"].at(-1).proxies, ["US fixed"]);
});
