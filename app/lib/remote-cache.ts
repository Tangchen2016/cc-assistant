import { UserError, privateHeaders } from "./errors.ts";
import { validateProfile, transformSource } from "./profile.ts";
import { fetchSource, parseSource } from "./source.ts";
import type { SourceConfig } from "./source.ts";
import type { Profile } from "./types.ts";
import { subscriptionPath, titleFilename } from "./subscription-name.ts";

export const MAX_REMOTE_SOURCE = 1_572_864;
export const MAX_REMOTE_BODY = 2_097_152;
export type RemoteCache = { profile: Profile; sourceYaml: string; sourceFetchedAt: string; userInfo?: string };
type LiveSource = { config: SourceConfig; fetchedAt: string; userInfo?: string };
type RemoteRenderOptions = { fetchLive?: (sourceUrl: string, signal: AbortSignal) => Promise<LiveSource>; timeoutMs?: number };
const bytes = (text: string) => new TextEncoder().encode(text).byteLength;

export function remoteUserInfo(value: unknown) {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string" || value.length > 256 || !/^(?:upload|download|total|expire)=\d+(?:\s*;\s*(?:upload|download|total|expire)=\d+)*\s*$/.test(value)) throw new UserError("订阅流量信息格式无效。");
  return value;
}

export function validateRemoteCache(input: unknown): RemoteCache {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new UserError("远程订阅资料格式无效。");
  const value = input as Record<string, unknown>;
  const profile = validateProfile(value.profile);
  if (bytes(JSON.stringify(profile)) > 65_536) throw new UserError("自定义规则配置超过 64 KiB 限制。", 413);
  if (typeof value.sourceYaml !== "string" || !value.sourceYaml) throw new UserError("请上传有效的原始源订阅 YAML。");
  if (bytes(value.sourceYaml) > MAX_REMOTE_SOURCE) throw new UserError("远程备用源订阅超过 1.5 MiB 限制。", 413);
  if (typeof value.sourceFetchedAt !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(value.sourceFetchedAt) || !Number.isFinite(Date.parse(value.sourceFetchedAt))) throw new UserError("源订阅更新时间无效。");
  const sourceFetchedAt = new Date(value.sourceFetchedAt).toISOString();
  const normalized = value.sourceFetchedAt.replace(/(?:\.(\d{1,3}))?Z$/, (_match, fraction: string | undefined) => `.${(fraction ?? "").padEnd(3, "0")}Z`);
  if (normalized !== sourceFetchedAt) throw new UserError("源订阅更新时间无效。");
  const userInfo = remoteUserInfo(value.userInfo);
  // Store the original source, never its already-enhanced output.
  transformSource(parseSource(value.sourceYaml), profile);
  return { profile, sourceYaml: value.sourceYaml, sourceFetchedAt, ...(userInfo ? { userInfo } : {}) };
}

export function remoteSubscriptionPath(name: string, id: string, key: string) {
  return subscriptionPath(name, id, key).replace(/^\/sub\//, "/remote-sub/");
}

export function validateRemoteIdentity(id: string, key: string) {
  if (!/^[a-f0-9]{32}$/.test(id) || !/^[a-f0-9]{64}$/.test(key)) throw new UserError("远程配置不存在或密钥无效。", 404);
}

async function fetchLiveSource(sourceUrl: string, signal: AbortSignal) {
  const fetcher: typeof fetch = (input, init = {}) => {
    const merged = init.signal ? AbortSignal.any([signal, init.signal]) : signal;
    return import("../../server/public-fetch.ts").then(({ publicFetch }) => publicFetch(input, { ...init, signal: merged }));
  };
  return fetchSource(sourceUrl, { fetch: fetcher });
}

export async function renderRemoteSubscription(cache: RemoteCache, options: RemoteRenderOptions = {}) {
  const profile = validateProfile(cache.profile);
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let source: LiveSource | undefined;
  try {
    const timeout = new Promise<never>((_accept, reject) => {
      timer = setTimeout(() => { controller.abort(); reject(new Error("live source timeout")); }, options.timeoutMs ?? 6000);
    });
    try { source = await Promise.race([(options.fetchLive ?? fetchLiveSource)(profile.sourceUrl, controller.signal), timeout]); }
    catch { /* A cached original source is the explicitly authorized offline backup. */ }
  } finally { if (timer) clearTimeout(timer); controller.abort(); }
  const mode = source ? "live" : "cache";
  if (!source) {
    if (typeof cache.sourceYaml !== "string" || bytes(cache.sourceYaml) > MAX_REMOTE_SOURCE) throw new UserError("远程备用源订阅无效，请在 App 中重新同步。", 502);
    source = { config: parseSource(cache.sourceYaml), fetchedAt: cache.sourceFetchedAt, userInfo: remoteUserInfo(cache.userInfo) };
  }
  const { yaml, warnings } = transformSource(source.config, profile);
  const headers = new Headers({
    ...privateHeaders, "Content-Type": "application/yaml; charset=utf-8", "Content-Disposition": titleFilename(profile.name),
    "X-Subscription-Source": mode, "X-Source-Updated-At": source.fetchedAt, "X-Subscription-Warnings": String(warnings.length),
  });
  const userInfo = remoteUserInfo(source.userInfo);
  if (userInfo) headers.set("Subscription-Userinfo", userInfo);
  return new Response(yaml, { headers });
}

export async function remoteDownload(
  id: string,
  key: string,
  find: (id: string, key: string) => Promise<RemoteCache>,
  options: RemoteRenderOptions = {},
) {
  validateRemoteIdentity(id, key);
  // Authenticate before any source fetch or cache content is exposed.
  const cache = await find(id, key);
  return renderRemoteSubscription(cache, options);
}
