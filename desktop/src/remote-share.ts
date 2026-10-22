import { spawn } from "node:child_process";
import { stringify } from "yaml";
import type { RemoteSubscription, SavedProfile } from "../../app/lib/types.ts";
import { fetchSource } from "../../app/lib/source.ts";
import { transformSource } from "../../app/lib/profile.ts";
import { UserError } from "../../app/lib/errors.ts";
import { curlFetch, localDns, systemProxy } from "./local-source.ts";
import type { LocalStore } from "./local-store.ts";

export const REMOTE_ORIGIN = "https://node.tangchen02.top";
export const LEGACY_REMOTE_ORIGIN = "https://cc-assistant-api.tangchen19942016.workers.dev";
export const REMOTE_ERROR = "远程同步失败，云端保留上次成功内容；请检查网络后重试。";
export const FIXED_EXIT_REMOTE_ERROR = "当前远程服务尚未验证支持固定出口，请使用本地订阅；已有远程订阅仍保留旧配置。";
const quote = (value: string) => `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r/g, "\\r").replace(/\n/g, "\\n")}"`;
type Method = "POST" | "PUT" | "DELETE";
export type RemoteTransport = (method: Method, path: string, data: unknown, key: string | undefined, signal: AbortSignal, origin?: string) => Promise<Record<string, unknown>>;
export type RemoteOptions = { transport?: RemoteTransport; fetchSource?: (url: string, signal: AbortSignal) => ReturnType<typeof fetchSource>; intervalMs?: number; fixedExitVerified?: boolean };

export function validateRemote(value: unknown): RemoteSubscription {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new UserError("远程订阅资料无效。", 502);
  const remote = value as RemoteSubscription;
  if (!/^[a-f0-9]{32}$/.test(remote.id) || !/^[a-f0-9]{64}$/.test(remote.manageKey) || !/^[a-f0-9]{64}$/.test(remote.downloadKey) || remote.manageKey === remote.downloadKey || !Number.isFinite(remote.updatedAt) || remote.updatedAt <= 0) throw new UserError("远程订阅资料无效。", 502);
  let url: URL;
  try { url = new URL(remote.subscriptionUrl); } catch { throw new UserError("远程订阅地址无效。", 502); }
  if (![REMOTE_ORIGIN, LEGACY_REMOTE_ORIGIN].includes(url.origin) || url.username || url.password || url.search || url.hash || !new RegExp(`^/remote-sub/${remote.id}/${remote.downloadKey}(?:/[^/]+)?$`).test(url.pathname)) throw new UserError("远程订阅地址不属于指定托管服务。", 502);
  return { id: remote.id, manageKey: remote.manageKey, downloadKey: remote.downloadKey, subscriptionUrl: url.href, updatedAt: remote.updatedAt, ...(remote.lastError ? { lastError: REMOTE_ERROR } : {}) };
}

// The fixed destination, request body and authorization enter curl through stdin.
export const remoteCurl: RemoteTransport = async (method, path, data, key, signal, origin = REMOTE_ORIGIN) => {
  if (![REMOTE_ORIGIN, LEGACY_REMOTE_ORIGIN].includes(origin)) throw new UserError("远程托管服务地址无效。", 400);
  if (!/^\/api\/remote-subscriptions(?:\/[a-f0-9]{32})?$/.test(path)) throw new UserError("远程操作地址无效。", 400);
  if (key !== undefined && !/^[a-f0-9]{64}$/.test(key)) throw new UserError("远程管理密钥无效。", 400);
  signal.throwIfAborted();
  const json = method === "DELETE" ? "" : JSON.stringify(data);
  if (Buffer.byteLength(json) > 1_572_864) throw new UserError("远程订阅内容超过 1.5 MiB 限制。", 413);
  const proxy = await systemProxy("https:");
  signal.throwIfAborted();
  const config = [
    `url = ${quote(`${origin}${path}`)}`, `request = ${quote(method)}`, 'proto = "=https"', 'proto-redir = "=https"',
    "silent", "compressed", "max-redirs = 0", "connect-timeout = 8", "max-time = 20", `proxy = ${quote(proxy)}`,
    `noproxy = ${quote(process.env.no_proxy ?? process.env.NO_PROXY ?? "")}`, 'header = "Cookie:"', 'header = "Content-Type: application/json"',
    ...(key ? [`header = ${quote(`Authorization: Bearer ${key}`)}`] : []), ...(json ? [`data-binary = ${quote(json)}`] : []),
    'write-out = "\\nSTUDIO_STATUS:%{http_code}"',
  ].join("\n");
  return new Promise((accept, reject) => {
    const child = spawn("/usr/bin/curl", ["-q", "--config", "-"], { stdio: ["pipe", "pipe", "ignore"] });
    const chunks: Buffer[] = []; let size = 0; let failure: Error | undefined;
    const abort = () => { failure = new UserError("远程同步已取消。", 502); child.kill("SIGKILL"); };
    const timer = setTimeout(abort, 22_000);
    signal.addEventListener("abort", abort, { once: true });
    child.stdin.on("error", () => undefined);
    child.on("error", () => { failure = new UserError(REMOTE_ERROR, 502); });
    child.stdout.on("data", (chunk: Buffer) => { size += chunk.length; if (size > 65_536) { failure = new UserError(REMOTE_ERROR, 502); child.kill("SIGKILL"); } else chunks.push(chunk); });
    child.on("close", (code) => {
      clearTimeout(timer); signal.removeEventListener("abort", abort);
      if (failure || code !== 0) { reject(failure ?? new UserError(REMOTE_ERROR, 502)); return; }
      const output = Buffer.concat(chunks).toString("utf8");
      const marker = output.lastIndexOf("\nSTUDIO_STATUS:");
      const status = Number(output.slice(marker + 15));
      if (marker < 0 || !Number.isInteger(status) || status < 200 || status >= 300) { reject(new UserError(REMOTE_ERROR, status === 404 ? 404 : 502)); return; }
      try { const parsed: unknown = JSON.parse(output.slice(0, marker)); if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error(); accept(parsed as Record<string, unknown>); }
      catch { reject(new UserError(REMOTE_ERROR, 502)); }
    });
    child.stdin.end(`${config}\n`);
    if (signal.aborted) abort();
  });
};

export class RemotePublisher {
  private readonly controller = new AbortController();
  private readonly queues = new Map<string, Promise<unknown>>();
  private readonly transport: RemoteTransport;
  private readonly fetcher: NonNullable<RemoteOptions["fetchSource"]>;
  private timer?: ReturnType<typeof setInterval>;
  private stopped = false;
  private refreshing = false;
  private readonly store: LocalStore;
  private readonly options: RemoteOptions;
  constructor(store: LocalStore, options: RemoteOptions = {}) {
    this.store = store; this.options = options;
    this.transport = options.transport ?? remoteCurl;
    this.fetcher = options.fetchSource ?? ((url, signal) => fetchSource(url, { resolve: localDns, fetch: (input, init) => curlFetch(input, { ...init, signal: init?.signal ? AbortSignal.any([init.signal, signal]) : signal }) }));
  }
  serialize<T>(id: string, action: () => Promise<T>): Promise<T> {
    const pending = (this.queues.get(id) ?? Promise.resolve()).catch(() => undefined).then(() => { this.controller.signal.throwIfAborted(); return action(); });
    this.queues.set(id, pending);
    void pending.finally(() => { if (this.queues.get(id) === pending) this.queues.delete(id); }).catch(() => undefined);
    return pending;
  }
  async publish(id: string, key: string, explicit = false) {
    return this.serialize(id, async () => {
      const record = await this.store.find(id, key);
      if (!explicit && !record.remote) return undefined;
      // Only the verified self-hosted service supports fixed-exit generation.
      if (record.profile.groups.some((group) => group.fixedExit !== undefined) && (this.options.fixedExitVerified === false || record.remote && new URL(record.remote.subscriptionUrl).origin === LEGACY_REMOTE_ORIGIN)) {
        if (record.remote) await this.store.setRemote(id, key, { ...record.remote, lastError: REMOTE_ERROR });
        throw new UserError(FIXED_EXIT_REMOTE_ERROR, 422);
      }
      let created: RemoteSubscription | undefined;
      try {
        const source = await this.freshSource(record.profile.sourceUrl);
        this.controller.signal.throwIfAborted();
        transformSource(source.config, record.profile);
        const payload = { profile: record.profile, sourceYaml: stringify(source.config, { lineWidth: 0 }), sourceFetchedAt: source.fetchedAt, ...(source.userInfo ? { userInfo: source.userInfo } : {}) };
        if (Buffer.byteLength(JSON.stringify(payload)) > 1_572_864) throw new UserError("远程订阅内容超过 1.5 MiB 限制。", 413);
        let remote: RemoteSubscription;
        if (record.remote) {
          const result = await this.transport("PUT", `/api/remote-subscriptions/${record.remote.id}`, payload, record.remote.manageKey, this.controller.signal, new URL(record.remote.subscriptionUrl).origin);
          remote = validateRemote({ ...record.remote, updatedAt: result.updatedAt, lastError: undefined });
        } else {
          const result = await this.transport("POST", "/api/remote-subscriptions", payload, undefined, this.controller.signal) as SavedProfile & { updatedAt: number };
          remote = validateRemote({ ...result, subscriptionUrl: `${REMOTE_ORIGIN}${result.subscriptionPath}` }); created = remote;
        }
        await this.store.setRemote(id, key, remote);
        return remote;
      } catch (error) {
        if (created && !this.stopped) { try { await this.transport("DELETE", `/api/remote-subscriptions/${created.id}`, undefined, created.manageKey, this.controller.signal); } catch { /* The management key was never exposed. */ } }
        if (record.remote && !this.stopped) { try { await this.store.setRemote(id, key, { ...record.remote, lastError: REMOTE_ERROR }); } catch { /* A concurrent removal invalidates this record. */ } }
        throw new UserError(error instanceof UserError && error.status === 413 ? error.message : REMOTE_ERROR, error instanceof UserError && error.status === 413 ? 413 : 502);
      }
    });
  }
  async remove(id: string, key: string) {
    return this.serialize(id, async () => {
      const record = await this.store.find(id, key);
      if (record.remote) {
        try { await this.transport("DELETE", `/api/remote-subscriptions/${record.remote.id}`, undefined, record.remote.manageKey, this.controller.signal, new URL(record.remote.subscriptionUrl).origin); }
        catch (error) { if (!(error instanceof UserError) || error.status !== 404) { await this.store.setRemote(id, key, { ...record.remote, lastError: REMOTE_ERROR }); throw new UserError(REMOTE_ERROR, 502); } }
        await this.store.setRemote(id, key, undefined);
      }
      return { removed: true };
    });
  }
  start() {
    if (this.timer || this.stopped || this.options.intervalMs === 0) return;
    const refresh = async () => {
      if (this.refreshing || this.stopped) return;
      this.refreshing = true;
      try {
        const records = await this.store.remoteRecords(); let cursor = 0;
        await Promise.all(Array.from({ length: Math.min(4, records.length) }, async () => { while (cursor < records.length && !this.stopped) { const record = records[cursor++]; try { await this.publish(record.id, record.manageKey); } catch { /* Status is retained in the local descriptor. */ } } }));
      } finally { this.refreshing = false; }
    };
    this.timer = setInterval(() => { void refresh().catch(() => undefined); }, this.options.intervalMs ?? 15 * 60_000); this.timer.unref();
    void refresh().catch(() => undefined);
  }
  private async freshSource(url: string) {
    const signal = this.controller.signal;
    signal.throwIfAborted();
    let timer: ReturnType<typeof setTimeout> | undefined;
    let abort: (() => void) | undefined;
    try {
      return await Promise.race([this.fetcher(url, signal), new Promise<never>((_accept, reject) => {
        abort = () => reject(new UserError("远程同步已取消。", 502));
        signal.addEventListener("abort", abort, { once: true });
        timer = setTimeout(() => reject(new UserError(REMOTE_ERROR, 502)), 16_000);
        if (signal.aborted) abort();
      })]);
    } finally { if (timer) clearTimeout(timer); if (abort) signal.removeEventListener("abort", abort); }
  }
  async stop() { this.stopped = true; if (this.timer) clearInterval(this.timer); this.controller.abort(); await Promise.allSettled([...this.queues.values()]); }
}
