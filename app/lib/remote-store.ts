import { and, eq } from "drizzle-orm";
import { getDb } from "../../db/index.ts";
import { remoteCaches } from "../../db/schema.ts";
import { randomKey, hashKey } from "./store.ts";
import { UserError } from "./errors.ts";
import type { Profile } from "./types.ts";
import { remoteSubscriptionPath, validateRemoteIdentity } from "./remote-cache.ts";
import type { RemoteCache } from "./remote-cache.ts";

export async function createRemoteCache(cache: RemoteCache) {
  const id = randomKey().slice(0, 32);
  const manageKey = randomKey();
  const downloadKey = randomKey();
  const now = Date.now();
  await getDb().insert(remoteCaches).values({
    id, editHash: await hashKey(manageKey), downloadHash: await hashKey(downloadKey),
    profileJson: JSON.stringify(cache.profile), sourceYaml: cache.sourceYaml, sourceFetchedAt: cache.sourceFetchedAt,
    userInfo: cache.userInfo ?? null, createdAt: now, updatedAt: now,
  });
  return { id, manageKey, downloadKey, subscriptionPath: cache.profile.client === "shadowrocket" ? `/remote-sub/${id}/${downloadKey}/claude-nodes.txt` : remoteSubscriptionPath(cache.profile.name, id, downloadKey), updatedAt: now };
}

export async function findRemoteCache(id: string, key: string, download = false) {
  validateRemoteIdentity(id, key);
  const [record] = await getDb().select().from(remoteCaches).where(and(eq(remoteCaches.id, id), eq(download ? remoteCaches.downloadHash : remoteCaches.editHash, await hashKey(key)))).limit(1);
  if (!record) throw new UserError("远程配置不存在或密钥无效。", 404);
  const cache: RemoteCache = {
    profile: JSON.parse(record.profileJson) as Profile, sourceYaml: record.sourceYaml,
    sourceFetchedAt: record.sourceFetchedAt, ...(record.userInfo ? { userInfo: record.userInfo } : {}),
  };
  return { record, cache };
}

export async function updateRemoteCache(id: string, key: string, cache: RemoteCache) {
  const { record } = await findRemoteCache(id, key);
  const updatedAt = Date.now();
  await getDb().update(remoteCaches).set({
    profileJson: JSON.stringify(cache.profile), sourceYaml: cache.sourceYaml, sourceFetchedAt: cache.sourceFetchedAt,
    userInfo: cache.userInfo ?? null, updatedAt,
  }).where(and(eq(remoteCaches.id, record.id), eq(remoteCaches.editHash, record.editHash)));
  return { saved: true, updatedAt };
}

export async function deleteRemoteCache(id: string, key: string) {
  const { record } = await findRemoteCache(id, key);
  await getDb().delete(remoteCaches).where(and(eq(remoteCaches.id, record.id), eq(remoteCaches.editHash, record.editHash)));
  return { deleted: true };
}
