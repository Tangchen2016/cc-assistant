import { randomBytes, timingSafeEqual } from "node:crypto";
import { mkdir, readFile, writeFile, rename, chmod } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Profile, SavedProfile, RemoteSubscription } from "../../app/lib/types.ts";
import { UserError } from "../../app/lib/errors.ts";
import { validateProfile } from "../../app/lib/profile.ts";
import { subscriptionPath } from "../../app/lib/subscription-name.ts";
import { validateRemote } from "./remote-share.ts";

type RecordEntry = { id: string; manageKey: string; downloadKey: string; profile: Profile; updatedAt: number; remote?: RemoteSubscription };
type State = { version: 1; records: RecordEntry[]; currentId: string | null; draft: Profile | null };
const freshState = (): State => ({ version: 1, records: [], currentId: null, draft: null });
const validId = (value: unknown): value is string => typeof value === "string" && /^[a-f0-9]{32}$/.test(value);
const validKey = (value: unknown): value is string => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
function matches(key: string, expected: string) { return validKey(key) && timingSafeEqual(Buffer.from(key, "hex"), Buffer.from(expected, "hex")); }
function descriptor(record: RecordEntry): SavedProfile { return { id: record.id, manageKey: record.manageKey, downloadKey: record.downloadKey, subscriptionPath: subscriptionPath(record.profile.name, record.id, record.downloadKey), ...(record.remote ? { remote: record.remote } : {}) }; }

// Drafts may have an empty URL or no selected nodes; they are not runnable profiles.
export function validateDraft(input: unknown): Profile {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new UserError("草稿格式无效。");
  const draft = input as Record<string, unknown>;
  const text = (value: unknown, max: number) => {
    if (typeof value !== "string" || value.length > max || /[\x00-\x1f\x7f]/.test(value)) throw new UserError("草稿字段无效或过长。");
    return value;
  };
  if (!Array.isArray(draft.groups) || draft.groups.length > 10 || !Array.isArray(draft.rules) || draft.rules.length > 100) throw new UserError("草稿组或规则数量超限。");
  return {
    name: text(draft.name, 100), sourceUrl: text(draft.sourceUrl, 4096),
    groups: draft.groups.map((value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new UserError("草稿代理组格式无效。");
      const group = value as Record<string, unknown>;
      if (!Array.isArray(group.nodes) || group.nodes.length > 100) throw new UserError("草稿节点数量超限。");
      let chain: { entry: string } | undefined;
      if (group.chain !== undefined) {
        if (!group.chain || typeof group.chain !== "object" || Array.isArray(group.chain)) throw new UserError("草稿链式前置格式无效。");
        chain = { entry: text((group.chain as Record<string, unknown>).entry, 256) };
      }
      return { name: text(group.name, 100), nodes: group.nodes.map((node) => text(node, 256)), ...(chain ? { chain } : {}) };
    }),
    rules: draft.rules.map((value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new UserError("草稿规则格式无效。");
      const rule = value as Record<string, unknown>;
      if (!["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD"].includes(String(rule.type))) throw new UserError("草稿规则类型无效。");
      return { type: rule.type as Profile["rules"][number]["type"], value: text(rule.value, 253), group: text(rule.group, 100) };
    }),
  };
}

export class LocalStore {
  private state: State = freshState();
  private queue: Promise<unknown> = Promise.resolve();
  readonly directory: string;
  constructor(directory = process.env.DESKTOP_DATA_DIR ?? join(homedir(), "Library", "Application Support", "Subscription Studio")) { this.directory = directory; }

  async load() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    await chmod(this.directory, 0o700);
    try {
      const text = await readFile(join(this.directory, "profiles.json"), "utf8");
      if (Buffer.byteLength(text) > 4 * 1024 * 1024) throw new Error("large state");
      const input = JSON.parse(text) as State;
      if (input.version !== 1 || !Array.isArray(input.records) || input.records.length > 50) throw new Error("invalid state");
      for (const record of input.records) {
        if (!validId(record.id) || !validKey(record.manageKey) || !validKey(record.downloadKey) || record.manageKey === record.downloadKey || !Number.isFinite(record.updatedAt)) throw new Error("invalid record");
        record.profile = validateProfile(record.profile);
        if (record.remote !== undefined) record.remote = validateRemote(record.remote);
      }
      if (new Set(input.records.map((record) => record.id)).size !== input.records.length) throw new Error("duplicate records");
      if (input.currentId !== null && !input.records.some(({ id }) => id === input.currentId)) throw new Error("invalid current");
      if (input.draft !== null) input.draft = validateDraft(input.draft);
      this.state = input;
      await chmod(join(this.directory, "profiles.json"), 0o600);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw new UserError("本地订阅资料无法读取，请保留资料文件后重新启动。", 500);
    }
    return this;
  }

  private async mutate<T>(change: (state: State) => T): Promise<T> {
    const operation = this.queue.then(async () => {
      const next = structuredClone(this.state);
      const result = change(next);
      const contents = JSON.stringify(next);
      if (Buffer.byteLength(contents) > 4 * 1024 * 1024) throw new UserError("本地订阅资料过大。", 413);
      const temp = join(this.directory, `.profiles-${randomBytes(8).toString("hex")}.tmp`);
      await writeFile(temp, contents, { mode: 0o600, flag: "wx" });
      await rename(temp, join(this.directory, "profiles.json"));
      this.state = next;
      return result;
    });
    this.queue = operation.catch(() => undefined);
    return operation;
  }

  async library() {
    await this.queue;
    const current = this.state.records.find(({ id }) => id === this.state.currentId);
    return structuredClone({ desktop: true, profiles: [...this.state.records].sort((a, b) => b.updatedAt - a.updatedAt).map((record) => ({ ...descriptor(record), name: record.profile.name })), current: current ? descriptor(current) : null, draft: this.state.draft });
  }

  async draft(input: unknown) {
    if (!input || typeof input !== "object" || Array.isArray(input)) throw new UserError("草稿格式无效。");
    const value = input as Record<string, unknown>;
    const profile = validateDraft(value.profile ?? value);
    return this.mutate((state) => {
      if ("current" in value) {
        if (value.current === null) state.currentId = null;
        else {
          const current = value.current as SavedProfile;
          const record = state.records.find(({ id }) => id === current?.id);
          if (!record || !matches(current.manageKey, record.manageKey)) throw new UserError("当前配置的管理密钥无效。", 401);
          state.currentId = record.id;
        }
      }
      state.draft = profile;
      return { saved: true };
    });
  }

  async find(id: string, key: string, download = false) {
    await this.queue;
    const record = this.state.records.find((entry) => entry.id === id);
    if (!validId(id) || !record || !matches(key, download ? record.downloadKey : record.manageKey)) throw new UserError("配置不存在或密钥无效。", 404);
    return structuredClone(record);
  }

  async remoteRecords() {
    await this.queue;
    return this.state.records.filter((record) => record.remote).map(({ id, manageKey }) => ({ id, manageKey }));
  }

  async setRemote(id: string, key: string, remote: RemoteSubscription | undefined) {
    const checked = remote === undefined ? undefined : validateRemote(remote);
    return this.mutate((state) => {
      const record = state.records.find((entry) => entry.id === id);
      if (!record || !matches(key, record.manageKey)) throw new UserError("配置不存在或密钥无效。", 404);
      if (checked) record.remote = checked;
      else delete record.remote;
      return { saved: true, ...(record.remote ? { remote: record.remote } : {}) };
    });
  }

  async create(profile: Profile) {
    return this.mutate((state) => {
      if (state.records.length >= 50) throw new UserError("最多保存 50 份订阅，请先删除不需要的配置。", 413);
      const record = { id: randomBytes(16).toString("hex"), manageKey: randomBytes(32).toString("hex"), downloadKey: randomBytes(32).toString("hex"), profile, updatedAt: Date.now() };
      state.records.push(record); state.currentId = record.id; state.draft = profile;
      return descriptor(record);
    });
  }

  async update(id: string, key: string, profile: Profile) {
    return this.mutate((state) => {
      const record = state.records.find((entry) => entry.id === id);
      if (!record || !matches(key, record.manageKey)) throw new UserError("配置不存在或密钥无效。", 404);
      record.profile = profile; record.updatedAt = Date.now(); state.currentId = id; state.draft = profile;
      return { saved: true };
    });
  }

  async remove(id: string, key: string) {
    return this.mutate((state) => {
      const record = state.records.find((entry) => entry.id === id);
      if (!record || !matches(key, record.manageKey)) throw new UserError("配置不存在或密钥无效。", 404);
      state.records = state.records.filter((entry) => entry.id !== id);
      if (state.currentId === id) { state.currentId = null; state.draft = null; }
      return { deleted: true };
    });
  }
}
