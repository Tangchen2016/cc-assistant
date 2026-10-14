import { and, eq } from "drizzle-orm";
import { getDb } from "../../db/index.ts";
import { profiles } from "../../db/schema.ts";
import type { Profile } from "./types.ts";
import { UserError } from "./errors.ts";

export function randomKey() {
  return Array.from(crypto.getRandomValues(new Uint8Array(32)), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
export async function hashKey(key: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function managementKey(request: Request) {
  const auth = request.headers.get("Authorization") ?? "";
  const key = /^Bearer ([a-f0-9]{64})$/.exec(auth)?.[1];
  if (!key) throw new UserError("管理密钥无效或缺失。", 401);
  return key;
}

export async function findProfile(id: string, key: string, download = false) {
  if (!/^[a-f0-9]{32}$/.test(id) || !/^[a-f0-9]{64}$/.test(key)) throw new UserError("配置不存在或密钥无效。", 404);
  const db = getDb();
  const [record] = await db.select().from(profiles).where(and(eq(profiles.id, id), eq(download ? profiles.downloadHash : profiles.editHash, await hashKey(key)))).limit(1);
  if (!record) throw new UserError("配置不存在或密钥无效。", 404);
  return { record, profile: JSON.parse(record.profileJson) as Profile };
}
