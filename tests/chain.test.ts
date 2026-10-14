import assert from "node:assert/strict";
import test from "node:test";
import { parse } from "yaml";
import { transformSource, validateProfile } from "../app/lib/profile.ts";
import type { Profile } from "../app/lib/types.ts";
import type { SourceConfig } from "../app/lib/source.ts";
import { validateDraft } from "../desktop/src/local-store.ts";

const source: SourceConfig = {
  proxies: [
    { name: "Entry", type: "socks5", server: "entry.example.com", port: 1080 },
    { name: "Exit", type: "http", server: "exit.example.com", port: 443, password: "synthetic-only" },
  ],
  "proxy-groups": [{ name: "General", type: "select", proxies: ["Entry", "Exit"] }],
  rules: ["MATCH,General"],
};
const profile: Profile = { name: "chain fixture", sourceUrl: "https://source.example.com/sub.yaml", groups: [{ name: "Claude", nodes: ["Exit"], chain: { entry: "Entry" } }], rules: [{ type: "DOMAIN-SUFFIX", value: "claude.ai", group: "Claude" }] };

test("chain adds an isolated exit clone and preserves original nodes/groups/global selection", () => {
  const before = structuredClone(source);
  const output = parse(transformSource(source, profile).yaml);
  assert.deepEqual(source, before);
  assert.deepEqual(output.proxies.slice(0, 2), source.proxies);
  assert.deepEqual(output["proxy-groups"][0], (source["proxy-groups"] as unknown[])[0]);
  const chained = output.proxies[2];
  assert.equal(chained["dialer-proxy"], "Entry");
  assert.equal(chained.password, "synthetic-only");
  assert.deepEqual(output["proxy-groups"][1].proxies, [chained.name]);
  assert.deepEqual(output.rules, ["DOMAIN-SUFFIX,claude.ai,Claude", "MATCH,General"]);
});

test("disappearing entry or exit rejects the entire chain instead of silently falling back direct", () => {
  for (const missing of ["Entry", "Exit"]) {
    const next = { ...source, proxies: source.proxies.filter(({ name }) => name !== missing) };
    const transformed = transformSource(next, profile);
    assert.equal(transformed.warnings.length, 1);
    const output = parse(transformed.yaml);
    assert.deepEqual(output["proxy-groups"].at(-1).proxies, ["REJECT"]);
    assert.equal(output.proxies.length, 1);
  }
});

test("self-chain, reserved entry and incomplete chain are rejected on save", () => {
  for (const entry of ["Exit", "DIRECT", "REJECT", "", "Entry\nother"]) assert.throws(() => validateProfile({ ...profile, groups: [{ ...profile.groups[0], chain: { entry } }] }));
  assert.equal(validateDraft({ ...profile, groups: [{ ...profile.groups[0], chain: { entry: "" } }] }).groups[0].chain?.entry, "");
});

test("cycles, opaque group dependency, generated-name collisions and existing exit chains cannot be overwritten", () => {
  const variants: SourceConfig[] = [
    { ...source, proxies: [{ ...source.proxies[0], "dialer-proxy": "Exit" }, source.proxies[1]] },
    { ...source, proxies: [{ ...source.proxies[0], "dialer-proxy": "General" }, source.proxies[1]] },
    { ...source, proxies: [source.proxies[0], { ...source.proxies[1], "dialer-proxy": "Entry" }] },
    { ...source, proxies: [...source.proxies, { ...source.proxies[0], name: "Claude · 链式出口 1" }] },
  ];
  for (const variant of variants) assert.throws(() => transformSource(variant, profile));
});
