import test from "node:test";
import assert from "node:assert/strict";
import { renderShadowrocket } from "../app/lib/shadowrocket.ts";
import { parseSource } from "../app/lib/source.ts";
import type { Profile } from "../app/lib/types.ts";
import { importLinks } from "../website/import/links.js";

const id = "a".repeat(32);
const source = () => parseSource("proxies:\n  - {name: HK, type: ss, server: hk.example.com, port: 443, cipher: aes-128-gcm, password: synthetic}\n  - {name: JP, type: ss, server: jp.example.com, port: 443, cipher: aes-128-gcm, password: second}\nproxy-groups:\n  - {name: General, type: select, proxies: [HK, JP, DIRECT]}\nrules: [DOMAIN-SUFFIX,other.example,Games]\n");
const profile = (): Profile => ({ name: "增强-测试", sourceUrl: "https://example.com/sub", groups: [{ name: "Claude", nodes: [], fixedExit: "vless://11111111-2222-4333-8444-555555555555@exit.example.com:443?security=tls&type=ws&path=%2Fsocket", chain: { entry: "General" } }], rules: [{ type: "DOMAIN-SUFFIX", value: "claude.ai", group: "Claude" }, { type: "DOMAIN-SUFFIX", value: "anthropic.com", group: "Claude" }, { type: "DOMAIN-SUFFIX", value: "claude.com", group: "Claude" }, { type: "DOMAIN-SUFFIX", value: "other.example", group: "Claude" }] });

test("module contains only Claude rules and protocol guards, without source policy groups or final rules", () => {
  const { text } = renderShadowrocket(source(), profile(), id, "shadowrocket-module");
  assert.deepEqual(text.match(/^\[.*\]$/gm), ["[Rule]"]);
  assert.equal(text.split("\n").filter(l => l.startsWith("DOMAIN-SUFFIX,")).length, 3);
  assert.equal(text.split("\n").filter(l => l.startsWith("AND,")).length, 3);
  assert.match(text, /\(PROTOCOL,UDP\)\),REJECT-NO-DROP/);
  assert.match(text, new RegExp(`DOMAIN-SUFFIX,claude.ai,CC-Claude-${id}-1`));
  assert.doesNotMatch(text, /General|Games|other.example|FINAL|GEOIP|\[General\]|\[Proxy Group\]|\[MITM\]/);
});
test("node export carries only explicit front and fixed exit with matching rule alias", () => {
  const { text } = renderShadowrocket(source(), profile(), id, "shadowrocket-nodes");
  const uris = Buffer.from(text, "base64").toString("utf8").split("\n");
  assert.equal(uris.length, 2);
  const front = new URL(uris[0]); const exit = new URL(uris[1]);
  assert.equal(front.protocol, "ss:"); assert.equal(front.hostname, "hk.example.com");
  assert.equal(Buffer.from(front.username, "base64").toString(), "aes-128-gcm:synthetic");
  assert.equal(exit.protocol, "vless:"); assert.equal(exit.hostname, "exit.example.com");
  assert.equal(exit.searchParams.get("chain"), `CC-Entry-${id}-1`);
  assert.equal(decodeURIComponent(exit.hash.slice(1)), `CC-Claude-${id}-1`);
  assert.equal(exit.searchParams.get("security"), "tls"); assert.equal(exit.searchParams.get("path"), "/socket");
  assert.doesNotMatch(Buffer.from(text, "base64").toString(), /General|jp.example.com|chain=PROXY/);
});
test("renaming source groups or changing ordinary source rules cannot alter exported Claude module", () => {
  const config = source(); const p = profile();
  const before = renderShadowrocket(config, p, id, "shadowrocket-module").text;
  config["proxy-groups"] = [{ name: "OtherProvider", type: "select", proxies: ["HK", "JP"] }];
  config.rules = ["MATCH,MissingOldGroup"]; p.groups[0].chain = { entry: "OtherProvider" };
  assert.equal(renderShadowrocket(config, p, id, "shadowrocket-module").text, before);
});
test("missing, dynamic, cyclic, already chained and unsupported fronts fail rather than bypass fixed exit", () => {
  for (const entry of ["Missing", "Loop", "Dynamic"]) {
    const config = source(); config["proxy-groups"] = [{ name: "Loop", proxies: ["Loop"] }, { name: "Dynamic", use: ["provider"] }];
    const p = profile(); p.groups[0].chain = { entry };
    assert.throws(() => renderShadowrocket(config, p, id, "shadowrocket-module"));
  }
  const config = source(); config.proxies[0]["dialer-proxy"] = "JP";
  assert.throws(() => renderShadowrocket(config, profile(), id, "shadowrocket-nodes"), /已有代理链/);
  delete config.proxies[0]["dialer-proxy"]; config.proxies[0].type = "hysteria2";
  assert.throws(() => renderShadowrocket(config, profile(), id, "shadowrocket-nodes"), /协议暂不支持/);
});
test("node-only group exports first selected fixed node and never ordinary subscription groups", () => {
  const p = profile(); p.groups = [{ name: "Claude", nodes: ["JP", "HK"] }];
  const text = Buffer.from(renderShadowrocket(source(), p, id, "shadowrocket-nodes").text, "base64").toString();
  assert.equal(text.split("\n").length, 1); assert.match(text, /jp.example.com/); assert.doesNotMatch(text, /hk.example.com/);
  p.groups[0].nodes = ["Removed"];
  assert.throws(() => renderShadowrocket(source(), p, id, "shadowrocket-module"), /已从源订阅移除/);
});
test("non-Claude rules and broad keyword matches cannot expand the module scope", () => {
  const p = profile(); p.rules = [{ type: "DOMAIN-SUFFIX", value: "notclaude.ai", group: "Claude" }, { type: "DOMAIN-KEYWORD", value: "claude", group: "Claude" }];
  assert.throws(() => renderShadowrocket(source(), p, id, "shadowrocket-module"), /没有 Claude/);
  assert.throws(() => renderShadowrocket(source(), profile(), "invalid", "shadowrocket-module"), /标识无效/);
});
test("guide derives distinct authenticated node/module links and rejects unrelated origins", () => {
  const address = `https://node.tangchen02.top/remote-sub/${id}/${"b".repeat(64)}/test.yaml`;
  const name = "增强-测试 & 日本 / + # ?";
  const data = importLinks(`#url=${encodeURIComponent(address)}&name=${encodeURIComponent(name)}`);
  assert.equal(new URL(data.nodes).searchParams.get("format"), "shadowrocket-nodes");
  assert.equal(new URL(data.module).searchParams.get("format"), "shadowrocket-module");
  assert.ok(new URL(data.module).pathname.endsWith("/claude.module"));
  assert.ok(new URL(data.nodes).pathname.endsWith("/claude-nodes.txt"));
  assert.equal(new URL(data.addModule).searchParams.get("module"), data.module);
  assert.equal(data.name, name); assert.ok(data.addNodes.startsWith("shadowrocket://add/sub://"));
  const raw = data.addNodes.slice("shadowrocket://add/sub://".length).split("?remark=");
  assert.equal(Buffer.from(raw[0], "base64").toString(), data.nodes);
  assert.equal(decodeURIComponent(raw[1]), name + " · Claude 节点");
  assert.equal(new URL(data.addNodes).hash, "");
  assert.equal(new URL(data.addNodes).searchParams.get("remark"), name + " · Claude 节点");
  for (const bad of [address.replace("node.tangchen02.top", "example.com"), address.replace("https:", "http:"), address + "?other=1"]) assert.throws(() => importLinks(`#url=${encodeURIComponent(bad)}`));
});
