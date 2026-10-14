import { stringify } from "yaml";
import { getSqlite } from "../db/index.ts";
import { hashKey } from "../app/lib/store.ts";
import { fetchSource, parseSource } from "../app/lib/source.ts";
import { transformSource } from "../app/lib/profile.ts";
import type { Profile } from "../app/lib/types.ts";

export async function fetchProfileSource(id: string, profile: Profile, fetchLive = fetchSource) {
  const sourceHash = await hashKey(profile.sourceUrl);
  let live: Awaited<ReturnType<typeof fetchSource>>;
  try { live = await fetchLive(profile.sourceUrl); }
  catch (error) {
    const cached = getSqlite().prepare("SELECT source_yaml, fetched_at, user_info FROM source_caches WHERE id=? AND source_url_hash=?").get(id, sourceHash);
    if (!cached) throw error;
    return { config: parseSource(String(cached.source_yaml)), fetchedAt: String(cached.fetched_at), userInfo: cached.user_info ? String(cached.user_info) : undefined, mode: "cache" };
  }
  // Invalid newly fetched routes must fail, rather than silently use old routes.
  transformSource(live.config, profile);
  await saveSourceCache(id, profile, live);
  return { ...live, mode: "live" };
}

export async function saveSourceCache(id: string, profile: Profile, live: Awaited<ReturnType<typeof fetchSource>>) {
  const sourceHash = await hashKey(profile.sourceUrl);
  getSqlite().prepare("INSERT INTO source_caches VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET source_url_hash=excluded.source_url_hash, source_yaml=excluded.source_yaml, fetched_at=excluded.fetched_at, user_info=excluded.user_info").run(id, sourceHash, stringify(live.config), live.fetchedAt, live.userInfo ?? null);
}
