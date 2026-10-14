import assert from "node:assert/strict";
import test from "node:test";
import { pingNodes, validatePingRequest } from "../app/lib/ping.ts";
import type { SourceConfig } from "../app/lib/source.ts";

const sourceUrl = "https://subscription.example.net/clash?token=synthetic-source-secret";
const source = (names = ["US fixed"], server = "proxy.example.net", port: unknown = 443): SourceConfig => ({
  proxies: names.map((name) => ({ name, type: "ss", server, port, password: "synthetic-node-secret" })),
});
const resolvePublic = async () => ["2001:4860:4860::8888", "8.8.8.8"];

test("ping request accepts only bounded unique node names and normalizes the source boundary", () => {
  assert.deepEqual(validatePingRequest({ sourceUrl, nodes: ["US fixed"], server: "127.0.0.1", port: 123 }), { sourceUrl, nodes: ["US fixed"] });
  for (const input of [
    null, [], "bad", { sourceUrl, nodes: [] }, { sourceUrl, nodes: ["US", "US"] },
    { sourceUrl, nodes: Array.from({ length: 11 }, (_, i) => `US${i}`) },
    { sourceUrl, nodes: [""] }, { sourceUrl, nodes: [12] }, { sourceUrl, nodes: ["x\nMATCH"] },
    { sourceUrl: "http://127.0.0.1/private", nodes: ["US"] },
  ]) assert.throws(() => validatePingRequest(input));
});

test("direct helper calls cannot exceed the batch limit or duplicate node names", async () => {
  const options = { connect: () => { throw new Error("unexpected connect"); } };
  for (const names of [[], ["US", "US"], Array.from({ length: 11 }, (_, i) => `US${i}`)]) {
    await assert.rejects(pingNodes(source(), names, options));
  }
});

test("successful TCP measurement connects to a validated public IP and closes the socket", async () => {
  const targets: Array<{ hostname: string; port: number }> = [];
  let closes = 0;
  let dnsSignal: AbortSignal | undefined;
  const result = await pingNodes(source(), ["US fixed"], {
    resolve: async (hostname, signal) => { assert.equal(hostname, "proxy.example.net"); dnsSignal = signal; return resolvePublic(); },
    connect: (target) => {
      targets.push(target);
      return { opened: Promise.resolve({ remoteAddress: target.hostname }), close: () => { closes++; } };
    },
  });
  assert.deepEqual(targets, [{ hostname: "8.8.8.8", port: 443 }]);
  assert.equal(result.results[0].status, "ok");
  assert.ok(Number.isFinite(result.results[0].latencyMs));
  assert.ok((result.results[0].latencyMs ?? -1) >= 0);
  assert.ok(Number.isFinite(Date.parse(result.measuredAt)));
  assert.equal(closes, 1);
  assert.equal(dnsSignal?.aborted, true);
  assert.doesNotMatch(JSON.stringify(result), /synthetic-node-secret|synthetic-source-secret|proxy\.example|8\.8\.8\.8/);
});

test("public literal IPv4/IPv6 skip DNS and retain the requested numeric port", async () => {
  for (const server of ["1.1.1.1", "[2001:4860:4860::8888]"]) {
    let target: { hostname: string; port: number } | undefined;
    const result = await pingNodes(source(["US fixed"], server, "8443"), ["US fixed"], {
      resolve: async () => { throw new Error("literal IP must not be resolved again"); },
      connect: (value) => { target = value; return { opened: Promise.resolve(), close: () => undefined }; },
    });
    assert.equal(result.results[0].status, "ok");
    assert.deepEqual(target, { hostname: server.replace(/^\[|\]$/g, ""), port: 8443 });
  }
});

test("any private, mixed or invalid DNS answer prevents a TCP connection", async () => {
  let connects = 0;
  for (const answers of [["127.0.0.1"], ["8.8.8.8", "10.0.0.1"], ["8.8.8.8", "::ffff:127.0.0.1"], ["2001:4860:4860::8888", "fc00::1"], ["8.8.8.8", "invalid-IP"]]) {
    const result = await pingNodes(source(), ["US fixed"], {
      resolve: async () => answers,
      connect: () => { connects++; throw new Error("private destination must not be connected"); },
    });
    assert.equal(result.results[0].status, "blocked");
    assert.equal(result.results[0].latencyMs, undefined);
  }
  assert.equal(connects, 0);
});

test("private or malformed source node hosts and ports are blocked before DNS and connect", async () => {
  let networkCalls = 0;
  const options = {
    resolve: async () => { networkCalls++; return ["8.8.8.8"]; },
    connect: () => { networkCalls++; throw new Error("unexpected connect"); },
  };
  for (const server of ["127.0.0.1", "169.254.169.254", "localhost.", "service.local", "[::1]", "proxy.example.net:443", "user@proxy.example.net", "proxy.example.net/private", "proxy.example.net#fragment"]) {
    const result = await pingNodes(source(["US fixed"], server), ["US fixed"], options);
    assert.equal(result.results[0].status, "blocked", server);
  }
  for (const port of [0, -1, 65_536, 1.5, "not-a-port", null]) {
    assert.equal((await pingNodes(source(["US fixed"], "proxy.example.net", port), ["US fixed"], options)).results[0].status, "blocked");
  }
  assert.equal(networkCalls, 0);
});

test("names missing from the current source cannot select arbitrary endpoints", async () => {
  let connects = 0;
  const result = await pingNodes(source(), ["Attacker supplied", "127.0.0.1:22"], {
    resolve: resolvePublic,
    connect: () => { connects++; throw new Error("unexpected connect"); },
  });
  assert.deepEqual(result.results.map((entry) => entry.status), ["unavailable", "unavailable"]);
  assert.equal(connects, 0);
});

test("failed connection and rejected closed/close promises are sanitized and handled", async () => {
  let closes = 0;
  const result = await pingNodes(source(), ["US fixed"], {
    resolve: resolvePublic,
    connect: () => ({
      opened: Promise.reject(new Error(`credentials synthetic-node-secret ${sourceUrl}`)),
      closed: Promise.reject(new Error("socket closed failure")),
      close: () => { closes++; return Promise.reject(new Error("close failure")); },
    }),
  });
  assert.equal(result.results[0].status, "unavailable");
  assert.equal(closes, 1);
  assert.doesNotMatch(JSON.stringify(result), /synthetic-node-secret|synthetic-source-secret/);
});

test("socket opening timeout closes the socket once and does not wait for close to settle", async () => {
  let closes = 0;
  const result = await pingNodes(source(), ["US fixed"], {
    resolve: resolvePublic, socketTimeoutMs: 5,
    connect: () => ({ opened: new Promise(() => undefined), close: () => { closes++; return new Promise<void>(() => undefined); } }),
  });
  assert.equal(result.results[0].status, "timeout");
  assert.equal(result.results[0].latencyMs, undefined);
  assert.equal(closes, 1);
});

test("DNS timeout is bounded even if the resolver ignores abort, and creates no socket", async () => {
  let signal: AbortSignal | undefined;
  let connects = 0;
  const result = await pingNodes(source(), ["US fixed"], {
    dnsTimeoutMs: 5,
    resolve: (_hostname, value) => { signal = value; return new Promise(() => undefined); },
    connect: () => { connects++; throw new Error("unexpected connect"); },
  });
  assert.equal(result.results[0].status, "timeout");
  assert.equal(signal?.aborted, true);
  assert.equal(connects, 0);
});

test("parallel TCP batches stay bounded at four and preserve request order", async () => {
  const names = Array.from({ length: 10 }, (_, i) => `US${i}`);
  let active = 0, peak = 0, connects = 0, closes = 0;
  const result = await pingNodes(source(names), names, {
    resolve: resolvePublic,
    connect: () => {
      active++; connects++; peak = Math.max(peak, active);
      return { opened: new Promise((resolve) => setTimeout(resolve, connects % 2 ? 8 : 2)), close: () => { active--; closes++; } };
    },
  });
  assert.equal(peak, 4);
  assert.equal(active, 0);
  assert.equal(connects, 10);
  assert.equal(closes, 10);
  assert.deepEqual(result.results.map((entry) => entry.name), names);
  assert.ok(result.results.every((entry) => entry.status === "ok"));
});
