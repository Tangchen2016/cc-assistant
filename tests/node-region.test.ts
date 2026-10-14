import assert from "node:assert/strict";
import test from "node:test";
import { isUSNode, prioritizeNodes } from "../app/lib/node-region.ts";

test("US node labels recognize Chinese, flag and bounded English country markers", () => {
  for (const name of [
    "美国专线 01", "🇺🇸 Los Angeles 01", "US", "us", "USA", "usa 02",
    "United States", "UNITED STATES premium", "UnitedStates", "united_states",
    "united-states 02", "[US] dedicated", "节点-US-01", "US01", "us123",
    "US-S01 | IEPL | x1.5", "节点 US01 | 备用", "ＵＳ０１", "ＵＳＡ ２",
  ]) assert.equal(isUSNode(name), true, name);
});

test("similar letters inside other countries or words do not classify as US", () => {
  for (const name of [
    "AUS", "Australia", "🇦🇺 Sydney 01", "Russia", "rus", "RUS01",
    "Business premium", "business", "use", "Loser", "MUS01", "USAGE",
    "1US", "US01x", "UnitedStatesman", "🇨🇦 Canada 01", "香港 HK01", "",
  ]) assert.equal(isUSNode(name), false, name);
});

test("an explicit US marker still counts when another country word is present", () => {
  assert.equal(isUSNode("Russia US01"), true);
  assert.equal(isUSNode("Australia to 🇺🇸"), true);
  assert.equal(isUSNode("US via Japan"), true);
});

test("US-first partition is stable and keeps all node objects and input order intact", () => {
  const nodes = [
    { name: "香港 HK01", type: "ss", selected: true },
    { name: "US02", type: "vmess", selected: false },
    { name: "日本 JP01", type: "trojan", selected: false },
    { name: "🇺🇸 LA01", type: "ss", selected: false },
    { name: "USA east", type: "socks5", selected: true },
    { name: "Australia", type: "ss", selected: false },
  ];
  const before = structuredClone(nodes);
  const output = prioritizeNodes(nodes);
  assert.deepEqual(output.map((node) => node.name), ["US02", "🇺🇸 LA01", "USA east", "香港 HK01", "日本 JP01", "Australia"]);
  assert.deepEqual(nodes, before);
  assert.notEqual(output, nodes);
  assert.equal(output.length, nodes.length);
  for (const node of nodes) assert.ok(output.includes(node), "Original node identity is preserved");
  assert.deepEqual(output.filter((node) => node.selected).map((node) => node.name), ["USA east", "香港 HK01"]);
});

test("empty, all-US and no-US inputs remain in their original relative order", () => {
  assert.deepEqual(prioritizeNodes([]), []);
  for (const names of [["US03", "US01", "美国02"], ["Japan", "Australia", "Russia"]]) {
    const nodes = names.map((name) => ({ name }));
    assert.deepEqual(prioritizeNodes(nodes), nodes);
  }
});
