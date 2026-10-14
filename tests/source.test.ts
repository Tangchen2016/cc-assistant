import assert from "node:assert/strict";
import test from "node:test";
import { errorResponse, readBoundedBody } from "../app/lib/errors.ts";
import { fetchSource, isPublicAddress, parseSource, validateSourceUrl } from "../app/lib/source.ts";

const sourceUrl = "https://subscription.example.net/clash?token=private-source-token";
const yaml = (password = "version-1") => `
mixed-port: 7890
mode: rule
proxies:
  - name: US fixed
    type: ss
    server: proxy.example.net
    port: 443
    cipher: aes-128-gcm
    password: ${password}
proxy-groups:
  - name: General
    type: select
    proxies: [US fixed, DIRECT]
rules:
  - MATCH,General
`;
const resolvePublic = async () => ["8.8.8.8", "2001:4860:4860::8888"];

function workerRequestContract(init?: RequestInit) {
  const options = init as (RequestInit & { cf?: { cacheTtl?: number } }) | undefined;
  if (options?.redirect === "error") throw new TypeError("workerd does not support redirect:error");
  if (options?.cache === "no-store" && options.cf?.cacheTtl !== undefined) {
    throw new TypeError("workerd cannot combine cache:no-store with cf.cacheTtl");
  }
}

test("default DNS and source fetching use request options supported by the Worker runtime", async () => {
  const seen: string[] = [];
  const fakeFetch: typeof fetch = async (url, init) => {
    workerRequestContract(init);
    const request = new URL(String(url));
    seen.push(request.hostname);
    assert.equal(init?.cache, "no-store");
    assert.equal(init?.redirect, "manual");
    if (request.hostname === "cloudflare-dns.com") {
      return Response.json({ Status: 0, Answer: request.searchParams.get("type") === "A" ? [{ type: 1, data: "8.8.8.8" }] : [{ type: 28, data: "2001:4860:4860::8888" }] });
    }
    assert.equal(request.href, sourceUrl);
    return new Response(yaml());
  };
  const result = await fetchSource(sourceUrl, { fetch: fakeFetch });
  assert.equal(result.config.proxies[0].name, "US fixed");
  assert.deepEqual(seen, ["cloudflare-dns.com", "cloudflare-dns.com", "subscription.example.net"]);
});

test("redirecting DNS service is rejected without following it or fetching source", async () => {
  const seen: string[] = [];
  const fakeFetch: typeof fetch = async (url, init) => {
    workerRequestContract(init);
    const request = new URL(String(url));
    seen.push(request.hostname);
    assert.equal(request.hostname, "cloudflare-dns.com");
    assert.equal(init?.redirect, "manual");
    return new Response(null, { status: 302, headers: { Location: "http://127.0.0.1/internal-dns" } });
  };
  await assert.rejects(fetchSource(sourceUrl, { fetch: fakeFetch }), /DNS/);
  assert.deepEqual(seen, ["cloudflare-dns.com", "cloudflare-dns.com"]);
});

test("every source access performs a fresh network fetch and observes changed credentials", async () => {
  let calls = 0;
  const requests: RequestInit[] = [];
  const fakeFetch: typeof fetch = async (url, init) => {
    assert.equal(String(url), sourceUrl);
    requests.push(init ?? {});
    calls++;
    return new Response(yaml(`version-${calls}`), { headers: { ETag: "same-etag" } });
  };
  const first = await fetchSource(sourceUrl, { fetch: fakeFetch, resolve: resolvePublic });
  const second = await fetchSource(sourceUrl, { fetch: fakeFetch, resolve: resolvePublic });
  assert.equal(calls, 2);
  assert.equal(first.config.proxies[0].password, "version-1");
  assert.equal(second.config.proxies[0].password, "version-2");
  for (const init of requests) {
    const headers = new Headers(init.headers);
    assert.equal(init.cache, "no-store");
    assert.equal(init.redirect, "manual");
    assert.equal(headers.get("cache-control"), "no-cache");
    assert.equal(headers.get("cookie"), null);
    assert.equal(headers.get("authorization"), null);
    assert.equal(headers.get("if-none-match"), null);
    assert.equal(headers.get("if-modified-since"), null);
  }
});

test("upstream failure after success returns an error instead of stale content", async () => {
  let calls = 0;
  const fakeFetch: typeof fetch = async () => ++calls === 1 ? new Response(yaml()) : new Response("bad gateway", { status: 503 });
  await fetchSource(sourceUrl, { fetch: fakeFetch, resolve: resolvePublic });
  await assert.rejects(fetchSource(sourceUrl, { fetch: fakeFetch, resolve: resolvePublic }), /HTTP 503/);
  assert.equal(calls, 2);
});

test("Cloudflare browser challenge after success is explained safely without stale fallback", async () => {
  let calls = 0, cancelled = false;
  const fakeFetch: typeof fetch = async () => {
    if (++calls === 1) return new Response(yaml());
    const body = new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(new TextEncoder().encode(`<html>Browser challenge ${sourceUrl}</html>`)); },
      cancel() { cancelled = true; },
    });
    return new Response(body, { status: 403, headers: { "cf-mitigated": "challenge", server: "cloudflare" } });
  };
  await fetchSource(sourceUrl, { fetch: fakeFetch, resolve: resolvePublic });
  let failure: unknown;
  await assert.rejects(fetchSource(sourceUrl, { fetch: fakeFetch, resolve: resolvePublic }), (error) => {
    failure = error;
    return error instanceof Error && /Cloudflare.*浏览器验证/.test(error.message);
  });
  const response = errorResponse(failure);
  const visible = await response.text();
  assert.equal(response.status, 502);
  assert.equal(calls, 2);
  assert.equal(cancelled, true);
  assert.match(visible, /云端无法直接读取|免验证订阅接口/);
  assert.doesNotMatch(visible, /private-source-token|subscription\.example|<html>|订阅无效/);
  assert.match(response.headers.get("cache-control") ?? "", /no-store/);
});

test("ordinary 403 is reported as access restriction without falsely claiming a browser challenge", async () => {
  let cancelled = false;
  const fakeFetch: typeof fetch = async () => new Response(new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(new TextEncoder().encode(`Forbidden sensitive provider body ${sourceUrl}`)); },
    cancel() { cancelled = true; },
  }), { status: 403, headers: { server: "cloudflare" } });
  let failure: unknown;
  await assert.rejects(fetchSource(sourceUrl, { fetch: fakeFetch, resolve: resolvePublic }), (error) => {
    failure = error;
    return error instanceof Error && /HTTP 403.*访问限制|订阅权限/.test(error.message);
  });
  const response = errorResponse(failure);
  const visible = await response.text();
  assert.equal(response.status, 502);
  assert.equal(cancelled, true);
  assert.doesNotMatch(visible, /浏览器验证|private-source-token|sensitive provider body|subscription\.example/);
});

test("network failures do not reveal source tokens in user-visible errors", async () => {
  const fakeFetch: typeof fetch = async () => { throw new Error(`Unable to fetch ${sourceUrl}`); };
  try {
    await fetchSource(sourceUrl, { fetch: fakeFetch, resolve: resolvePublic });
    assert.fail("fetch should fail");
  } catch (error) {
    const response = errorResponse(error);
    const body = await response.text();
    assert.equal(response.status, 502);
    assert.doesNotMatch(body, /private-source-token|subscription\.example/);
    assert.match(response.headers.get("cache-control") ?? "", /no-store/);
  }
  assert.doesNotMatch(await errorResponse(new Error(sourceUrl)).text(), /private-source-token/);
});

test("non-public IPv4, IPv6 and mapped IPv6 are rejected", () => {
  for (const address of ["0.0.0.0", "127.0.0.1", "10.2.3.4", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "198.18.0.1", "192.0.2.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "240.0.0.1", "::", "::1", "fc00::1", "fe80::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:192.168.1.1", "not-an-ip"]) {
    assert.equal(isPublicAddress(address), false, address);
  }
  for (const address of ["8.8.8.8", "1.1.1.1", "2001:4860:4860::8888", "::ffff:8.8.8.8"]) {
    assert.equal(isPublicAddress(address), true, address);
  }
});

test("URL validation rejects credentials, unsupported schemes and local literal addresses", () => {
  for (const url of ["file:///etc/passwd", "ftp://example.net/a", "https://user:pass@example.net/a", "https://example.net/a#secret", "http://localhost/a", "http://localhost./a", "http://service.local/a", "http://service.local./a", "http://internal/a", "http://127.1/a", "http://2130706433/a", "http://0x7f000001/a", "http://[::1]/a", "http://[::ffff:127.0.0.1]/a"]) {
    assert.throws(() => validateSourceUrl(url), Error, url);
  }
  assert.equal(validateSourceUrl(sourceUrl).href, sourceUrl);
});

test("default DNS verification checks both families and blocks a private answer before source fetch", async () => {
  const queried: string[] = [];
  const fakeFetch: typeof fetch = async (url) => {
    const request = new URL(String(url));
    assert.equal(request.hostname, "cloudflare-dns.com");
    queried.push(request.searchParams.get("type") ?? "");
    return Response.json({ Status: 0, Answer: [{ type: request.searchParams.get("type") === "A" ? 1 : 28, data: request.searchParams.get("type") === "A" ? "8.8.8.8" : "::1" }] });
  };
  await assert.rejects(fetchSource(sourceUrl, { fetch: fakeFetch }), /内网|特殊/);
  assert.deepEqual(queried.sort(), ["A", "AAAA"]);
});

test("only bounded numeric subscription usage metadata is forwarded", async () => {
  const good = "upload=1; download=2; total=1000; expire=1800000000";
  const fakeFetch: typeof fetch = async () => new Response(yaml(), { headers: { "Subscription-Userinfo": good } });
  assert.equal((await fetchSource(sourceUrl, { fetch: fakeFetch, resolve: resolvePublic })).userInfo, good);
  for (const bad of ["upload=1; token=secret", "upload=NaN; total=1", "upload=" + "1".repeat(300)]) {
    const badFetch: typeof fetch = async () => new Response(yaml(), { headers: { "Subscription-Userinfo": bad } });
    assert.equal((await fetchSource(sourceUrl, { fetch: badFetch, resolve: resolvePublic })).userInfo, undefined);
  }
});

test("any non-public DNS answer blocks the fetch, including mixed IPv4/IPv6", async () => {
  let calls = 0;
  const fakeFetch: typeof fetch = async () => { calls++; return new Response(yaml()); };
  for (const addresses of [[], ["127.0.0.1"], ["8.8.8.8", "10.0.0.1"], ["8.8.8.8", "::ffff:127.0.0.1"], ["8.8.8.8", "fe80::1"]]) {
    await assert.rejects(fetchSource(sourceUrl, { fetch: fakeFetch, resolve: async () => addresses }), /内网|特殊/);
  }
  assert.equal(calls, 0);
});

test("redirect destinations are revalidated and private targets never requested", async () => {
  for (const target of ["http://127.0.0.1/private", "http://[::1]/private", "https://internal.example.net/private"]) {
    const seen: string[] = [];
    const fakeFetch: typeof fetch = async (url) => {
      seen.push(String(url));
      return new Response(null, { status: 302, headers: { Location: target } });
    };
    const resolve = async (host: string) => host === "internal.example.net" ? ["192.168.1.1"] : ["8.8.8.8"];
    await assert.rejects(fetchSource(sourceUrl, { fetch: fakeFetch, resolve }), /内网|特殊/);
    assert.deepEqual(seen, [sourceUrl]);
  }
});

test("a public relative redirect is followed with fresh DNS verification", async () => {
  const seen: string[] = [];
  let resolutions = 0;
  const fakeFetch: typeof fetch = async (url) => {
    seen.push(String(url));
    return seen.length === 1 ? new Response(null, { status: 307, headers: { Location: "/updated.yaml" } }) : new Response(yaml());
  };
  await fetchSource(sourceUrl, { fetch: fakeFetch, resolve: async () => { resolutions++; return ["8.8.8.8"]; } });
  assert.deepEqual(seen, [sourceUrl, "https://subscription.example.net/updated.yaml"]);
  assert.equal(resolutions, 2);
});

test("endless redirects stop at a bounded number of attempts", async () => {
  let calls = 0;
  const fakeFetch: typeof fetch = async () => { calls++; return new Response(null, { status: 302, headers: { Location: "/again" } }); };
  await assert.rejects(fetchSource(sourceUrl, { fetch: fakeFetch, resolve: resolvePublic }), /重定向/);
  assert.ok(calls <= 6);
});

test("parser rejects duplicate keys, duplicate node names, malformed formats and circular aliases", () => {
  for (const invalid of [
    "<html>Cloudflare challenge</html>",
    "c3M6Ly9ub3QtYS1jbGFzaC1maWxl",
    "proxies: []",
    "proxies: [broken",
    "proxies: [{name: US, type: ss}, {name: US, type: ss}]",
    "proxies: [{name: US, type: ss}]\nmode: rule\nmode: direct",
    "proxies: [{name: US, type: ss}]\ncycle: &self [*self]",
    "proxies: [{name: US, type: ss}]\n__proto__: {polluted: yes}",
    "proxies: [{name: US, type: ss}]\nrules: [12]",
  ]) assert.throws(() => parseSource(invalid), Error, invalid.slice(0, 60));
});

test("size limits apply both to parsed content and streamed network bodies", async () => {
  assert.throws(() => parseSource("x".repeat(2 * 1024 * 1024 + 1)), /2 MiB/);
  const fakeFetch: typeof fetch = async () => new Response("x".repeat(2 * 1024 * 1024 + 1));
  await assert.rejects(fetchSource(sourceUrl, { fetch: fakeFetch, resolve: resolvePublic }), /2 MiB/);
});

test("JSON body limits cover actual body size even without content length", async () => {
  const request = new Request("https://app.example.net/api/profiles", { method: "POST", body: JSON.stringify({ value: "x".repeat(100) }) });
  await assert.rejects(readBoundedBody(request, 32), /配置过大/);
  const invalid = new Request("https://app.example.net/api/profiles", { method: "POST", body: "{not-json" });
  await assert.rejects(readBoundedBody(invalid), /JSON/);
});
