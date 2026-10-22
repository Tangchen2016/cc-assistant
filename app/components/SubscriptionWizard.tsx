"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { ArrowLeft, ArrowRight, Check, Copy, Eye, EyeOff, GitBranch, Link2, LoaderCircle, Plus, RefreshCw, Settings2, Trash2 } from "lucide-react";
import type { Group, Inspection, Profile, RemoteSubscription, SavedProfile } from "../lib/types";
import { AUTO_CHAIN_ENTRY, parseFixedExitLink } from "../lib/fixed-exit";
import { subscriptionPath } from "../lib/subscription-name";
import GroupEditor from "./GroupEditor";
import RuleEditor from "./RuleEditor";
import RemoteSubscriptionPanel from "./RemoteSubscriptionPanel";
import useNodeLatency, { type PingResponse } from "./useNodeLatency";
import { recommendedClaudeRules } from "../lib/claude-rules";

type Stage = "list" | "source" | "configure" | "review" | "done";
type Entry = SavedProfile & { name: string; profile?: Profile; unavailable?: boolean };
type DesktopState = { profiles: Entry[]; current: SavedProfile | null; draft: Profile | null };
const LIBRARY = "cc-assistant-library";
const LEGACY = "subscription-enhancer-profile";
const fresh = (): Profile => ({ name: "Claude 专属订阅", sourceUrl: "", groups: [{ name: "Claude 固定节点", nodes: [] }], rules: recommendedClaudeRules.map(rule => ({ ...rule, group: "Claude 固定节点" })) });
async function request<T>(path: string, body?: unknown, key?: string, method?: string, signal?: AbortSignal): Promise<T> {
  const response = await fetch(path, { method: method ?? (body ? "POST" : "GET"), headers: { ...(body || method === "DELETE" ? { "Content-Type": "application/json" } : {}), ...(key ? { Authorization: `Bearer ${key}` } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}), signal, cache: "no-store" });
  const data = await response.json().catch(() => ({ error: `请求失败（HTTP ${response.status}）` }));
  if (!response.ok) {
    const message = data && typeof data === "object" && "error" in data ? data.error : undefined;
    throw new Error(typeof message === "string" ? message : "请求失败，请重试。");
  }
  return data as T;
}
function validEntry(value: unknown): value is Entry {
  if (!value || typeof value !== "object") return false;
  const v = value as Entry;
  return /^[a-f0-9]{32}$/.test(v.id) && /^[a-f0-9]{64}$/.test(v.manageKey) && /^[a-f0-9]{64}$/.test(v.downloadKey);
}
function storeBrowser(entries: Entry[]) {
  localStorage.setItem(LIBRARY, JSON.stringify(entries.map(({ id, manageKey, downloadKey, subscriptionPath, name }) => ({ id, manageKey, downloadKey, subscriptionPath, name }))));
}
function hostOf(source: string) { try { return new URL(source).hostname; } catch { return "—"; } }
function fixedExitLabel(group: Group) {
  if (group.fixedExit === undefined) return group.nodes.join("、");
  try { const proxy = parseFixedExitLink(group.fixedExit); return `固定出口 · ${proxy.server}:${proxy.port}`; }
  catch { return "固定出口（待填写有效链接）"; }
}
function groupError(profile: Profile, inspection: Inspection | null) {
  if (!profile.groups.length || profile.groups.some(g => !g.name.trim() || (g.fixedExit === undefined ? !g.nodes.length : !g.fixedExit.trim()))) return "请为每个代理组填写名称，并选择节点或填写固定出口分享链接。";
  if (new Set(profile.groups.map(g => g.name.trim())).size !== profile.groups.length) return "代理组名称不能重复。";
  if (profile.groups.some(g => g.fixedExit !== undefined && g.chain && !g.chain.entry)) return "请为固定出口选择前置代理组。";
  if (profile.groups.some(g => g.fixedExit === undefined && g.chain && (!g.chain.entry || g.nodes.includes(g.chain.entry)))) return "请为链式代理选择不同于出口节点的前置节点。";
  try { for (const group of profile.groups) if (group.fixedExit !== undefined) parseFixedExitLink(group.fixedExit); }
  catch { return "固定出口分享链接无效，仅支持 VLESS + WebSocket + TLS。"; }
  const nodes = new Set(inspection?.nodes.map(n => n.name));
  if (profile.groups.some(g => g.fixedExit === undefined && [...g.nodes, ...(g.chain ? [g.chain.entry] : [])].some(n => !nodes.has(n)))) return "所选节点已不在当前订阅中，请重新选择。";
  if (profile.groups.some(g => g.fixedExit !== undefined && g.chain && g.chain.entry !== AUTO_CHAIN_ENTRY && !inspection?.sourceGroups.includes(g.chain.entry))) return "请为固定出口重新选择源订阅中的前置代理组。";
  if (!profile.rules.length || profile.rules.some(r => !r.value.trim() || !profile.groups.some(g => g.name === r.group))) return "请填写有效域名，并为每条规则选择代理组。";
  return "";
}

export default function SubscriptionWizard() {
  const [desktop] = useState(() => typeof window !== "undefined" && window.__SUBSCRIPTION_DESKTOP__ === true);
  const [stage, setStage] = useState<Stage>("list");
  const [entries, setEntries] = useState<Entry[]>([]);
  const [profile, setProfile] = useState<Profile>(fresh);
  const [saved, setSaved] = useState<SavedProfile | null>(null);
  const [inspection, setInspection] = useState<Inspection | null>(null);
  const [activeGroup, setActiveGroup] = useState(0);
  const [busy, setBusy] = useState("restore");
  const [error, setError] = useState("");
  const [origin, setOrigin] = useState("");
  const [showSource, setShowSource] = useState(false);
  const [copied, setCopied] = useState("");
  const [deleteId, setDeleteId] = useState<string | null>(null);
  const [remoteDelete, setRemoteDelete] = useState(false);
  const [draft, setDraft] = useState<{ profile: Profile; current: SavedProfile | null } | null>(null);
  const [login, setLogin] = useState<{ enabled: boolean; needsApproval?: boolean } | null>(null);
  const [ready, setReady] = useState(false);
  const writes = useRef<Promise<unknown>>(Promise.resolve());
  const pendingCopy = useRef("");
  const latency = useNodeLatency((nodes, signal) => profile.groups[activeGroup]?.fixedExit !== undefined ? Promise.reject(new Error("固定出口链路请在 Clash 中验证。")) : request<PingResponse>("/api/ping", { sourceUrl: profile.sourceUrl.trim(), nodes, ...(desktop && profile.groups[activeGroup]?.chain ? { chainEntry: profile.groups[activeGroup].chain!.entry } : {}) }, undefined, undefined, signal));

  useEffect(() => { window.scrollTo(0, 0); }, [stage]);

  const loadLibrary = useCallback(async () => {
    let records: Entry[] = [];
    let desktopState: DesktopState | null = null;
    if (desktop) { desktopState = await request<DesktopState>("/api/desktop"); records = desktopState.profiles; }
    else {
      try {
        const list = JSON.parse(localStorage.getItem(LIBRARY) ?? "[]");
        if (Array.isArray(list)) records = list.filter(validEntry).slice(0, 100);
        const previous = JSON.parse(localStorage.getItem(LEGACY) ?? "null");
        if (validEntry(previous) && !records.some(r => r.id === previous.id)) records.push(previous);
      } catch { /* Malformed browser metadata cannot grant access to a configuration. */ }
      const hash = new URLSearchParams(window.location.hash.slice(1));
      const imported = { id: hash.get("id"), manageKey: hash.get("key"), downloadKey: hash.get("download"), subscriptionPath: "", name: "导入的配置" };
      if (validEntry(imported) && !records.some(r => r.id === imported.id)) records.push(imported);
    }
    const rows = await Promise.all(records.map(async entry => {
      try {
        const { profile: p } = await request<{ profile: Profile }>(`/api/profiles/${entry.id}`, undefined, entry.manageKey);
        return { ...entry, name: p.name, profile: p, subscriptionPath: subscriptionPath(p.name, entry.id, entry.downloadKey), unavailable: false };
      } catch { return { ...entry, name: entry.name || "已保存的配置", unavailable: true }; }
    }));
    setEntries(rows);
    if (!desktop) { storeBrowser(rows); localStorage.removeItem(LEGACY); }
    if (desktopState?.draft?.sourceUrl && JSON.stringify(desktopState.draft) !== JSON.stringify(rows.find(r => r.id === desktopState?.current?.id)?.profile ?? fresh())) setDraft({ profile: desktopState.draft, current: desktopState.current });
    return rows;
  }, [desktop]);
  useEffect(() => {
    async function restore() {
      await Promise.resolve(); setOrigin(window.location.origin);
      try { await loadLibrary(); setReady(true); }
      catch (e) { setError(e instanceof Error ? e.message : "配置列表读取失败。"); }
      finally { setBusy(""); }
    }
    void restore();
  }, [loadLibrary]);
  useEffect(() => {
    if (!desktop || !ready) return;
    if (stage === "list") {
      const finishPendingWrites = () => writes.current.then(() => undefined);
      window.__flushSubscriptionDraft = finishPendingWrites;
      return () => { if (window.__flushSubscriptionDraft === finishPendingWrites) delete window.__flushSubscriptionDraft; };
    }
    function flush() {
      const write = writes.current.catch(() => undefined).then(() => request("/api/desktop/draft", { profile, current: saved }, undefined, "PUT"));
      writes.current = write;
      return write.then(() => undefined);
    }
    window.__flushSubscriptionDraft = flush;
    const timer = setTimeout(() => { void flush().catch(() => setError("草稿保存失败，请重试。")); }, 250);
    return () => { clearTimeout(timer); if (window.__flushSubscriptionDraft === flush) delete window.__flushSubscriptionDraft; };
  }, [desktop, ready, stage, profile, saved]);
  useEffect(() => {
    if (!desktop) return;
    function result(event: Event) {
      const d = (event as CustomEvent<{ action?: string; ok?: boolean; enabled?: boolean; needsApproval?: boolean; error?: string }>).detail;
      if (["loginItem", "getLoginItem", "setLoginItem"].includes(d?.action ?? "")) {
        if (d.ok && typeof d.enabled === "boolean") setLogin({ enabled: d.enabled, needsApproval: d.needsApproval });
        else setError(d.error || "登录启动设置读取失败。");
      } else if (!d?.ok) setError(d?.error || "系统操作失败。");
      else if (d.action === "copy") { setCopied(pendingCopy.current); setTimeout(() => setCopied(""), 1800); }
    }
    window.addEventListener("desktop-result", result);
    window.webkit?.messageHandlers?.desktop?.postMessage({ action: "getLoginItem" });
    return () => window.removeEventListener("desktop-result", result);
  }, [desktop]);

  function edit(next: Profile) {
    if (next.sourceUrl !== profile.sourceUrl) {
      latency.reset(); setInspection(null);
      next = { ...next, groups: next.groups.map(group => group.fixedExit !== undefined && group.chain && group.chain.entry !== AUTO_CHAIN_ENTRY ? { ...group, chain: { entry: "" } } : group) };
    }
    setProfile(next); setError("");
  }
  function updateGroup(index: number, group: Group) {
    latency.reset(); const old = profile.groups[index].name;
    edit({ ...profile, groups: profile.groups.map((g, i) => i === index ? group : g), rules: profile.rules.map(r => r.group === old ? { ...r, group: group.name } : r) });
  }
  function newConfig() { latency.reset(); setProfile(fresh()); setSaved(null); setInspection(null); setActiveGroup(0); setError(""); setStage("source"); setDraft(null); window.history.replaceState(null, "", "/"); }
  async function openConfig(entry: Entry) {
    setBusy("open"); setError("");
    try {
      const p = entry.profile ?? (await request<{ profile: Profile }>(`/api/profiles/${entry.id}`, undefined, entry.manageKey)).profile;
      latency.reset(); setProfile(p); setSaved(entry); setInspection(null); setActiveGroup(0); setStage("configure");
      setBusy("inspect");
      try { setInspection(await request<Inspection>("/api/inspect", { sourceUrl: p.sourceUrl })); }
      catch { setError("已显示保存的节点与规则。源订阅暂时无法刷新，可稍后点击刷新节点重试。"); }
    } catch (e) { setError(e instanceof Error ? e.message : "读取失败。"); }
    finally { setBusy(""); }
  }
  async function confirmSource() {
    setBusy("inspect"); setError(""); latency.reset();
    try {
      const data = await request<Inspection>("/api/inspect", { sourceUrl: profile.sourceUrl.trim() });
      setInspection(data);
      setProfile(p => ({ ...p, sourceUrl: p.sourceUrl.trim(), name: !saved && p.name === "Claude 专属订阅" ? `增强-${data.sourceName || "源订阅"}`.slice(0, 100) : p.name }));
      setStage("configure");
    } catch (e) { setError(e instanceof Error ? e.message : "订阅解析失败。"); }
    finally { setBusy(""); }
  }
  function review() { const message = groupError(profile, inspection); if (message) { setError(message); return; } setError(""); setStage("review"); }
  async function generate() {
    const message = groupError(profile, inspection); if (message || !profile.name.trim()) { setError(message || "请填写订阅名称。"); return; }
    setBusy("save"); setError("");
    try {
      await writes.current.catch(() => undefined);
      const body = { ...profile, name: profile.name.trim() };
      let record: SavedProfile;
      if (saved) {
        const result = await request<{ remote?: RemoteSubscription }>(`/api/profiles/${saved.id}`, body, saved.manageKey, "PUT");
        record = { ...saved, ...(result.remote ? { remote: result.remote } : {}), subscriptionPath: subscriptionPath(body.name, saved.id, saved.downloadKey) };
      } else record = await request<SavedProfile>("/api/profiles", body);
      setSaved(record); setProfile(body);
      const next = [{ ...record, name: body.name, profile: body }, ...entries.filter(e => e.id !== record.id)];
      setEntries(next); if (!desktop) { storeBrowser(next); localStorage.removeItem(LEGACY); }
      setStage("done"); setDraft(null);
    } catch (e) { setError(e instanceof Error ? e.message : "生成失败。"); }
    finally { setBusy(""); }
  }
  async function goList() {
    setBusy("restore"); setError("");
    try { await window.__flushSubscriptionDraft?.(); await loadLibrary(); setStage("list"); window.history.replaceState(null, "", "/"); }
    catch (e) { setError(e instanceof Error ? e.message : "读取失败。"); }
    finally { setBusy(""); }
  }
  async function remove(entry: Entry) {
    setBusy("delete"); setError("");
    try {
      await request(`/api/profiles/${entry.id}`, undefined, entry.manageKey, "DELETE");
      const next = entries.filter(e => e.id !== entry.id); setEntries(next); if (!desktop) storeBrowser(next); setDeleteId(null);
    } catch (e) { setError(e instanceof Error ? e.message : "删除失败。"); }
    finally { setBusy(""); }
  }
  async function copy(value: string, label: string) {
    try {
      if (desktop) {
        const bridge = window.webkit?.messageHandlers?.desktop;
        if (!bridge) throw new Error("复制功能不可用。");
        pendingCopy.current = label; bridge.postMessage({ action: "copy", text: value }); return;
      }
      await navigator.clipboard.writeText(value);
      setCopied(label); setTimeout(() => setCopied(""), 1800);
    } catch { setError("无法复制，请手动选择地址。"); }
  }
  function importClash(url: string) {
    window.webkit?.messageHandlers?.desktop?.postMessage({ action: "importClash", url: `clash://install-config?${new URLSearchParams({ url, name: profile.name })}` });
  }
  async function syncRemote() {
    if (!saved) return;
    setBusy("remote"); setError("");
    try {
      await window.__flushSubscriptionDraft?.();
      const result = await request<{ remote: RemoteSubscription }>(`/api/profiles/${saved.id}/remote`, {}, saved.manageKey);
      setSaved(p => p ? { ...p, remote: result.remote } : p);
    } catch (e) { setError(e instanceof Error ? e.message : "同步失败。"); }
    finally { setBusy(""); }
  }
  async function stopRemote() {
    if (!saved || !remoteDelete) return;
    setBusy("remote"); setError("");
    try { await request(`/api/profiles/${saved.id}/remote`, undefined, saved.manageKey, "DELETE"); setSaved(p => { if (!p) return p; const next = { ...p }; delete next.remote; return next; }); setRemoteDelete(false); }
    catch (e) { setError(e instanceof Error ? e.message : "停止失败。"); }
    finally { setBusy(""); }
  }
  const url = saved ? origin + saved.subscriptionPath : "";
  const step = stage === "source" ? 1 : stage === "configure" ? 2 : 3;
  return <div className="site-shell web-shell wizard-shell">
    <header className="wizard-header"><div className="wizard-brand"><span><GitBranch size={20} /></span><strong>{desktop ? "Clash 增强" : "cc助手"}</strong></div>{desktop && login && <label className="wizard-startup"><input type="checkbox" checked={login.enabled} onChange={e => window.webkit?.messageHandlers?.desktop?.postMessage({ action: "setLoginItem", enabled: e.target.checked })} />登录时启动{login.needsApproval && <button className="button text-button" onClick={() => window.webkit?.messageHandlers?.desktop?.postMessage({ action: "openLoginSettings" })}>系统授权</button>}</label>}</header>
    <main className={`wizard-main wizard-${stage}`}>
      {stage === "list" ? <>
        <div className="wizard-heading"><div><h1>为 Claude 配置独立线路</h1><p>基于现有订阅，为 Claude 指定专用节点；有静态代理时，可通过链式代理固定最终出口 IP。生成新订阅地址后导入 Clash 使用。</p></div><button className="button primary" onClick={newConfig} disabled={!!busy}><Plus size={16} />新增配置</button></div>
        {error && <div className="notice error" role="alert">{error}</div>}
        {draft && <div className="wizard-draft"><span>有一份未完成的配置</span><button className="button text-button" onClick={() => { setProfile(draft.profile); setSaved(draft.current); setInspection(null); setStage("source"); setError(""); }}>继续配置<ArrowRight size={14} /></button></div>}
        {busy === "restore" ? <div className="wizard-empty"><LoaderCircle className="spin" size={24} /><p>正在读取配置…</p></div> : !entries.length ? <div className="wizard-empty"><span className="wizard-empty-icon"><GitBranch size={28} /></span><h2>还没有增强订阅</h2><p>添加源订阅，为 Claude 选择固定节点，生成新的订阅地址。</p><button className="button primary" onClick={newConfig} disabled={!!busy}><Plus size={16} />新增第一个配置</button></div> : <div className="wizard-library"><div className="library-head"><span>订阅配置 · {entries.length}</span><button className="button text-button" disabled={!!busy} onClick={() => void goList()}><RefreshCw size={13} />刷新列表</button></div>{entries.map(entry => <article className="library-row" key={entry.id}><span className="library-icon"><GitBranch size={18} /></span><div className="library-content"><h2>{entry.name}</h2><p>{entry.unavailable ? "暂时无法读取，请重试" : `${hostOf(entry.profile?.sourceUrl ?? "")} · ${entry.profile?.groups.length ?? 0} 个代理组 · ${entry.profile?.rules.length ?? 0} 条域名规则`}</p>{entry.profile && <div className="library-nodes">{entry.profile.groups.flatMap(g => g.fixedExit !== undefined ? [fixedExitLabel(g)] : g.nodes).slice(0, 3).map((name, i) => <span key={`${name}-${i}`}>{name}</span>)}</div>}</div><div className="library-actions">{deleteId === entry.id ? <><span>删除后地址失效</span><button className="button danger-text" onClick={() => void remove(entry)} disabled={!!busy}>确认删除</button><button className="button secondary" onClick={() => setDeleteId(null)}>取消</button></> : <><button className="button secondary" onClick={() => void copy(origin + entry.subscriptionPath, entry.id)} disabled={entry.unavailable}>{copied === entry.id ? <Check size={14} /> : <Copy size={14} />}{copied === entry.id ? "已复制" : "复制地址"}</button><button className="button secondary" onClick={() => { if (entry.profile) { setProfile(entry.profile); setSaved(entry); setStage("done"); setError(""); } }} disabled={!!busy || !entry.profile}>查看地址</button><button className="button secondary" onClick={() => void openConfig(entry)} disabled={!!busy}><Settings2 size={14} />编辑</button><button className="icon-button danger" aria-label={`删除 ${entry.name}`} onClick={() => setDeleteId(entry.id)} disabled={!!busy}><Trash2 size={16} /></button></>}</div></article>)}</div>}
      </> : <>
        <div className="wizard-heading"><div><button className="wizard-back" onClick={() => void goList()} disabled={!!busy}><ArrowLeft size={14} />配置列表</button><h1>{saved ? "编辑增强订阅" : "新增增强订阅"}</h1><p>为 Claude 设置独立线路，切换其他代理组时仍使用所选节点。支持链式代理，经机场前置连接静态代理，固定最终出口 IP。</p></div></div>
        <ol className="wizard-steps" aria-label="配置步骤">{["输入订阅", "详细配置", "确认并生成"].map((label, index) => <li key={label} className={step === index + 1 ? "active" : step > index + 1 ? "complete" : ""}><button type="button" aria-current={step === index + 1 ? "step" : undefined} disabled={!!busy || (index > 0 && !inspection)} onClick={() => { if (index === 2) review(); else { setStage(index === 0 ? "source" : "configure"); setError(""); } }}><span>{step > index + 1 ? <Check size={13} /> : index + 1}</span>{label}</button></li>)}</ol>
        {error && <div className="notice error" role="alert">{error}</div>}
        {stage === "source" && <section className="wizard-card wizard-source-card"><h2>添加源订阅</h2><p className="wizard-description">输入 Clash / Mihomo 订阅地址，解析后继续配置节点和规则。</p><label className="input-label" htmlFor="wizard-source">源订阅地址</label><div className="secret-input"><Link2 size={16} /><input id="wizard-source" type={showSource ? "url" : "password"} value={profile.sourceUrl} onChange={e => { edit({ ...profile, sourceUrl: e.target.value }); setInspection(null); }} autoComplete="off" placeholder="https://example.com/subscribe?token=…" disabled={!!busy} onKeyDown={e => { if (e.key === "Enter" && profile.sourceUrl.trim()) void confirmSource(); }} /><button className="icon-button" aria-label={showSource ? "隐藏订阅地址" : "显示订阅地址"} onClick={() => setShowSource(p => !p)}>{showSource ? <EyeOff size={16} /> : <Eye size={16} />}</button></div><p className="helper">支持包含内嵌节点的 YAML 订阅；地址不会在列表中完整展示。</p><div className="wizard-actions"><button className="button secondary" onClick={() => void goList()} disabled={!!busy}>取消</button><button className="button primary" onClick={() => void confirmSource()} disabled={!!busy || !profile.sourceUrl.trim()}>{busy ? <LoaderCircle className="spin" size={15} /> : null}{busy ? "正在解析" : "确定并继续"}<ArrowRight size={14} /></button></div></section>}
        {stage === "configure" && <><div className="wizard-source-summary"><span>{hostOf(profile.sourceUrl)}</span><span>{busy === "inspect" ? "正在刷新节点…" : inspection ? `${inspection.nodes.length} 个节点 · ${inspection.sourceGroups.length} 个原有代理组` : "已显示保存的配置"}</span><button className="button text-button" disabled={!!busy} onClick={() => void confirmSource()}><RefreshCw size={13} />刷新节点</button></div><div className="wizard-configure-grid"><GroupEditor groups={profile.groups} nodes={inspection?.nodes ?? []} sourceGroups={inspection?.sourceGroups ?? []} activeGroup={activeGroup} onSelect={i => { latency.reset(); setActiveGroup(i); }} onAdd={() => { let n = profile.groups.length + 1; while (profile.groups.some(g => g.name === `自定义组 ${n}`)) n++; edit({ ...profile, groups: [...profile.groups, { name: `自定义组 ${n}`, nodes: [] }] }); setActiveGroup(profile.groups.length); }} onRemove={i => { const name = profile.groups[i].name; edit({ ...profile, groups: profile.groups.filter((_, n) => n !== i), rules: profile.rules.filter(r => r.group !== name) }); setActiveGroup(0); latency.reset(); }} onUpdate={updateGroup} disabled={!!busy} latency={latency} desktop={desktop} onCopyFixedExit={value => void copy(value, `fixed-exit-${activeGroup}`)} fixedExitCopied={copied === `fixed-exit-${activeGroup}`} /><RuleEditor groups={profile.groups} rules={profile.rules} defaultGroup={profile.groups[activeGroup]?.name ?? ""} onChange={rules => edit({ ...profile, rules })} disabled={!!busy} /></div><div className="wizard-actions"><button className="button secondary" onClick={() => { latency.reset(); setStage("source"); setError(""); }} disabled={!!busy}><ArrowLeft size={14} />{saved ? "更换源订阅" : "上一步"}</button><button className="button primary" onClick={review} disabled={!!busy}>下一步：确认配置<ArrowRight size={14} /></button></div></>}
        {stage === "review" && <section className="wizard-card"><h2>确认增强订阅</h2><p className="wizard-description">确认节点和域名规则后，生成可导入 Clash 的新地址。</p><label className="input-label" htmlFor="wizard-name">订阅名称</label><input id="wizard-name" value={profile.name} maxLength={100} onChange={e => edit({ ...profile, name: e.target.value })} disabled={!!busy} /><div className="wizard-review-summary"><div><h3>固定节点</h3>{profile.groups.map(g => <div className="review-group" key={g.name}><strong>{g.name}</strong><span>{g.chain ? `${g.chain.entry === AUTO_CHAIN_ENTRY ? "自动测速前置" : g.chain.entry} → ` : ""}{fixedExitLabel(g)}</span></div>)}</div><div><h3>域名转发规则</h3>{profile.rules.map((r, i) => <div className="review-rule" key={i}><code>{r.value}</code><span>→ {r.group}</span></div>)}</div></div><p className="helper">保留原订阅的节点和规则，自定义规则优先匹配。更新时实时拉取源订阅。</p><div className="wizard-actions"><button className="button secondary" onClick={() => { setStage("configure"); setError(""); }} disabled={!!busy}><ArrowLeft size={14} />返回修改</button><button className="button primary" onClick={() => void generate()} disabled={!!busy}>{busy ? <LoaderCircle className="spin" size={15} /> : <Link2 size={15} />}{busy ? "正在生成" : saved ? "确认并保存修改" : "确认并生成地址"}</button></div></section>}
        {stage === "done" && saved && <><section className="wizard-card wizard-result"><span className="wizard-success"><Check size={24} /></span><h2>增强订阅已生成</h2><p className="wizard-description">{profile.name}</p><label className="input-label" htmlFor="wizard-url">{desktop ? "本机订阅地址" : "增强订阅地址"}</label><input id="wizard-url" value={url} readOnly onFocus={e => e.target.select()} /><div className="wizard-result-actions"><button className="button primary" onClick={() => void copy(url, "result")}>{copied === "result" ? <Check size={15} /> : <Copy size={15} />}{copied === "result" ? "已复制" : "复制地址"}</button>{desktop ? <button className="button secondary" onClick={() => importClash(url)}>导入 Clash Party</button> : <a className="button secondary" href={`clash://install-config?${new URLSearchParams({ url, name: profile.name })}`}>导入 Clash Party</a>}<button className="button secondary" onClick={() => void goList()}>完成，返回列表</button></div><p className="helper">{desktop ? "本机地址需要 cc助手保持运行。其他设备请使用下方远程地址。" : "源站暂时不可用时使用最近成功的源缓存，重新应用当前规则。"}</p>{!desktop && <button className="button text-button" onClick={() => void copy(`${origin}/#id=${saved.id}&key=${saved.manageKey}&download=${saved.downloadKey}`, "manage")}>{copied === "manage" ? "管理链接已复制" : "复制管理链接"}</button>}</section>{desktop && <RemoteSubscriptionPanel remote={saved.remote} dirty={false} busy={busy} copied={copied === "remote"} fixedExit={profile.groups.some(g => g.fixedExit !== undefined)} confirmDelete={remoteDelete} onSync={() => void syncRemote()} onCopy={() => { if (saved.remote) void copy(saved.remote.subscriptionUrl, "remote"); }} onImport={() => { if (saved.remote) importClash(saved.remote.subscriptionUrl); }} onConfirmDelete={setRemoteDelete} onDelete={() => void stopRemote()} />}</>}
      </>}
    </main>
  </div>;
}
