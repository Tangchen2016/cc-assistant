import assert from "node:assert/strict";
import test from "node:test";
import { normalizeUserInfo } from "../app/lib/source.ts";

test("normalizeUserInfo keeps numeric fields and drops an empty expire", () => {
  assert.equal(normalizeUserInfo("upload=1; download=2; total=300; expire="), "upload=1; download=2; total=300");
  assert.equal(normalizeUserInfo("upload=0;total=100"), "upload=0; total=100");
  assert.equal(normalizeUserInfo("expire="), undefined);
  assert.equal(normalizeUserInfo("download=1\r\nAuthorization: secret"), undefined);
  assert.equal(normalizeUserInfo("upload=1; token=secret"), undefined);
  assert.equal(normalizeUserInfo(null), undefined);
});
