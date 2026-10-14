import assert from "node:assert/strict";
import test from "node:test";
import { sourceName, subscriptionPath, titleFilename } from "../app/lib/subscription-name.ts";

const id = "a".repeat(32), key = "b".repeat(64);
const sourceUrl = "https://subscription.example.net/subscribe/private-path-token?token=private-query-token&name=secret.yaml";

test("RFC 5987 UTF-8 filename wins over ASCII filename and Profile-Title", () => {
  const headers = new Headers({
    "Content-Disposition": `attachment; filename="fallback.yaml"; filename*=UTF-8'zh-CN'${encodeURIComponent("我的机场.yaml")}`,
    "Profile-Title": "Other name",
  });
  assert.equal(sourceName(headers, sourceUrl), "我的机场");
});

test("quoted and unquoted Content-Disposition filenames are recognized", () => {
  for (const [header, expected] of [
    ['attachment; filename="My Airport.yaml"', "My Airport"],
    ['inline; filename=Airport.yml; other=value', "Airport"],
    ['attachment; FILENAME="Quoted\\\" Airport.YAML"', 'Quoted" Airport'],
  ]) assert.equal(sourceName(new Headers({ "Content-Disposition": header }), sourceUrl), expected);
});

test("malformed RFC filename falls back to ordinary filename rather than throwing", () => {
  assert.equal(sourceName(new Headers({ "Content-Disposition": "attachment; filename*=UTF-8''%not-valid; filename=fallback.yaml" }), sourceUrl), "fallback");
});

test("an unclosed quoted filename is ignored in favor of valid title metadata", () => {
  assert.equal(sourceName(new Headers({ "Content-Disposition": 'attachment; filename="unclosed.yaml', "Profile-Title": "Valid title" }), sourceUrl), "Valid title");
});

test("UTF-8 Base64 Profile-Title and plain titles are decoded safely", () => {
  assert.equal(sourceName(new Headers({ "Profile-Title": `base64:${Buffer.from("日本与美国专线.yml").toString("base64")}` }), sourceUrl), "日本与美国专线");
  assert.equal(sourceName(new Headers({ "Profile-Title": "My airport.yaml" }), sourceUrl), "My airport");
});

test("invalid Base64, invalid UTF-8 and empty names never become subscription titles", () => {
  for (const title of ["base64:invalid###", "base64:/w==", "base64:", "..", ".", " "]) {
    assert.equal(sourceName(new Headers({ "Profile-Title": title }), sourceUrl), undefined, title);
  }
  assert.equal(sourceName(new Headers({ "Profile-Title": "base64:invalid###" }), "https://example.net/config.yaml"), "config");
});

test("URL fallback uses only a YAML filename, never opaque path tokens, query names or credentials", () => {
  assert.equal(sourceName(new Headers(), sourceUrl), undefined);
  assert.equal(sourceName(new Headers(), "https://example.net/sub?filename=title.yaml&token=private"), undefined);
  assert.equal(sourceName(new Headers(), "https://user:password@example.net/private-token"), undefined);
  assert.equal(sourceName(new Headers(), "https://example.net/config.yml?token=private"), "config");
  assert.equal(sourceName(new Headers(), `https://example.net/${encodeURIComponent("机场 A.yaml")}?token=private`), "机场 A");
  assert.equal(sourceName(new Headers(), "https://example.net/%invalid.yaml?token=private"), undefined);
});

test("control characters and path separators are removed from decoded naming metadata", () => {
  const unsafe = "../Airport\\Route\r\nInjected\u0000.yaml";
  const headers = new Headers({ "Content-Disposition": `attachment; filename*=UTF-8''${encodeURIComponent(unsafe)}` });
  const name = sourceName(headers, sourceUrl);
  assert.ok(name);
  assert.doesNotMatch(name, /[\x00-\x1f\x7f/\\]/);
  assert.match(name, /AirportRouteInjected/);
});

test("source names are bounded and truncation does not leave an unpaired surrogate", () => {
  const title = "a".repeat(79) + "😀";
  const name = sourceName(new Headers({ "Profile-Title": `base64:${Buffer.from(title).toString("base64")}` }), sourceUrl);
  assert.ok(name && name.length <= 80);
  assert.doesNotThrow(() => encodeURIComponent(name));
});

test("download header uses an ASCII fallback and percent-encoded UTF-8 name", () => {
  const header = titleFilename("增强-我的机场");
  assert.match(header, /filename="enhanced\.yaml"/);
  const encoded = /filename\*=UTF-8''([^;]+)/.exec(header)?.[1];
  assert.ok(encoded);
  assert.equal(decodeURIComponent(encoded), "增强-我的机场.yaml");
  assert.doesNotMatch(header, /[\r\n]/);
  assert.doesNotThrow(() => new Headers({ "Content-Disposition": header }));
});

test("friendly subscription URL encodes cosmetic names and preserves authorization components", () => {
  const path = subscriptionPath("增强-我的机场", id, key);
  const parts = path.split("/");
  assert.deepEqual(parts.slice(0, 4), ["", "sub", id, key]);
  assert.equal(decodeURIComponent(parts[4]), "增强-我的机场.yaml");
  assert.equal(parts.length, 5);
  assert.equal(new URL(path, "https://app.example.net").pathname, path);
});

test("path and header names cannot inject new segments or headers and avoid duplicate extension", () => {
  for (const name of ["增强-原名.yaml", "增强-原名.YML", "../../unsafe\r\nX-Injected:yes\\route", "..", ".", ""]) {
    const path = subscriptionPath(name, id, key);
    assert.equal(path.split("/").length, 5);
    assert.doesNotMatch(decodeURIComponent(path.split("/").at(-1) ?? ""), /[\r\n/\\]/);
    assert.doesNotMatch(titleFilename(name), /[\r\n]/);
  }
  assert.equal(decodeURIComponent(subscriptionPath("增强-原名.yaml", id, key).split("/").at(-1) ?? ""), "增强-原名.yaml");
  assert.equal(decodeURIComponent(subscriptionPath("", id, key).split("/").at(-1) ?? ""), "增强-订阅.yaml");
});
