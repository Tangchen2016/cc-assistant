import test from "node:test";
import assert from "node:assert/strict";
import { validateProfile, transformSource } from "../app/lib/profile.ts";
import { validateRemoteCache, renderRemoteSubscription } from "../app/lib/remote-cache.ts";
import { importLinks } from "../website/import/links.js";
import type { Profile } from "../app/lib/types.ts";

const id = "a".repeat(32);
const profile = (): Profile => ({ client: "shadowrocket", name: "手机专用", sourceUrl: "", groups: [{ name: "Claude", nodes: [], fixedExit: "vless://11111111-2222-4333-8444-555555555555@exit.example.com:443?security=tls&type=ws&path=%2Fsocket" }], rules: ["anthropic.com", "claude.ai", "claude.com"].map(value => ({ type: "DOMAIN-SUFFIX", value, group: "Claude" })) });

test("independent mobile profile accepts only static exit and Claude rules without source credentials", () => {
  assert.equal(validateProfile(profile()).client, "shadowrocket");
  const cache = validateRemoteCache({ profile: profile() });
  assert.equal(cache.sourceYaml, "");
  assert.equal(cache.profile.sourceUrl, "");
  for (const changed of [
    { ...profile(), sourceUrl: "https://example.com/private-subscription" },
    { ...profile(), client: "unknown" },
    { ...profile(), groups: [{ ...profile().groups[0], chain: { entry: "HK" } }] },
    { ...profile(), groups: [{ ...profile().groups[0], nodes: ["HK"] }] },
    { ...profile(), groups: [{ name: "Claude", nodes: [] }] },
    { ...profile(), rules: [{ type: "DOMAIN-SUFFIX", value: "example.com", group: "Claude" }] },
    { ...profile(), rules: [{ type: "DOMAIN-KEYWORD", value: "claude", group: "Claude" }] },
  ]) assert.throws(() => validateRemoteCache({ profile: changed }));
  assert.throws(() => validateRemoteCache({ profile: profile(), sourceYaml: "private" }));
  assert.throws(() => validateRemoteCache({ profile: profile(), userInfo: "download=1" }));
  assert.throws(() => transformSource({ proxies: [] }, profile()));
});

test("both mobile exports and default download work with no source fetch or source snapshot", async () => {
  const cache = validateRemoteCache({ profile: profile() });
  let fetched = false;
  const options = { identity: id, fetchLive: async () => { fetched = true; throw new Error("must never fetch"); } };
  const nodes = await renderRemoteSubscription(cache, options);
  assert.equal(nodes.status, 200);
  assert.equal(nodes.headers.get("X-Subscription-Source"), "standalone");
  assert.equal(nodes.headers.get("Subscription-Userinfo"), null);
  const uris = Buffer.from(await nodes.text(), "base64").toString().split("\n");
  assert.equal(uris.length, 1);
  const exit = new URL(uris[0]);
  assert.equal(exit.hostname, "exit.example.com");
  assert.equal(exit.searchParams.get("chain"), null);
  assert.equal(exit.searchParams.get("security"), "tls");
  const moduleResponse = await renderRemoteSubscription(cache, { ...options, format: "shadowrocket-module" });
  const text = await moduleResponse.text();
  assert.deepEqual(text.match(/^\[.*\]$/gm), ["[Rule]"]);
  assert.equal(text.split("\n").filter(row => row.startsWith("DOMAIN-SUFFIX,")).length, 3);
  assert.equal(text.split("\n").filter(row => row.startsWith("AND,")).length, 3);
  assert.match(text, new RegExp(`DOMAIN-SUFFIX,claude.ai,${exit.hash.slice(1)}`));
  assert.doesNotMatch(text, /FINAL,|GEOIP,|\[Proxy Group\]|CC-Entry/);
  await assert.rejects(renderRemoteSubscription(cache, { ...options, format: "clash" }));
  assert.equal(fetched, false);
});

test("independent guide retains setup mode while node and module URLs remain separately authenticated", () => {
  const address = `https://node.tangchen02.top/remote-sub/${id}/${"b".repeat(64)}/claude-nodes.txt`;
  const data = importLinks(`#url=${encodeURIComponent(address)}&name=mobile&mode=shadowrocket`);
  assert.equal(data.standalone, true);
  assert.equal(new URL(data.nodes).pathname.split("/")[3], "b".repeat(64));
  assert.equal(new URL(data.module).searchParams.get("format"), "shadowrocket-module");
  assert.equal(importLinks(`#url=${encodeURIComponent(address)}&name=clash`).standalone, false);
});
