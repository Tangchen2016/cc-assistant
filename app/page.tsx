"use client";

import { useEffect, useRef, useState } from "react";
import { ArrowDownToLine, Check, Copy, Eye, EyeOff, GitBranch, Link2, LoaderCircle, Plus, RefreshCw, ShieldCheck, Network, ListFilter, FileCode2 } from "lucide-react";
import type { Group, Inspection, Profile, RemoteSubscription, SavedProfile } from "./lib/types";
import GroupEditor from "./components/GroupEditor";
import RuleEditor from "./components/RuleEditor";
import RemoteSubscriptionPanel from "./components/RemoteSubscriptionPanel";
import useNodeLatency, { type PingResponse } from "./components/useNodeLatency";
import { subscriptionPath } from "./lib/subscription-name";

declare global {
  interface Window {
    __SUBSCRIPTION_DESKTOP__?: boolean;
    __flushSubscriptionDraft?: () => Promise<void>;
    webkit?: { messageHandlers?: { desktop?: { postMessage: (message: { action: "importClash"; url: string } | { action: "copy"; text: string } | { action: "quitReady"; ok: boolean; error?: string } | { action: "getLoginItem" | "openLoginSettings" } | { action: "setLoginItem"; enabled: boolean }) => void } } };
  }
}
type LibraryProfile = SavedProfile & { name: string };
type DesktopState = { desktop: true; profiles: LibraryProfile[]; current: SavedProfile | null; draft: Profile | null };

const STORAGE = "subscription-enhancer-profile";
const freshProfile = (): Profile => ({ name: "Claude 专属订阅", sourceUrl: "", groups: [{ name: "Claude 固定节点", nodes: [] }], rules: ["anthropic.com", "claude.ai", "claude.com"].map((value) => ({ type: "DOMAIN-SUFFIX", value, group: "Claude 固定节点" })) });

async function api<T>(path: string, body?: unknown, key?: string, method?: string, signal?: AbortSignal): Promise<T> {
  const response = await fetch(path, {
    method: method ?? (body ? "POST" : "GET"),
    headers: { ...(body || method === "DELETE" ? { "Content-Type": "application/json" } : {}), ...(key ? { Authorization: `Bearer ${key}` } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}), cache: "no-store", signal,
  });
  const fallback = `服务返回 HTTP ${response.status}，请稍后重试`;
  if (!response.headers.get("Content-Type")?.toLowerCase().includes("application/json")) throw new Error(fallback);
  let data: unknown;
  try { data = await response.json(); } catch { throw new Error(fallback); }
  if (!response.ok) {
    const message = data && typeof data === "object" && "error" in data ? data.error : undefined;
    throw new Error(typeof message === "string" ? message : fallback);
  }
  return data as T;
}

export default function Home() {
  const [profile, setProfile] = useState<Profile>(freshProfile);
  const [inspection, setInspection] = useState<Inspection | null>(null);
  const [inspectedUrl, setInspectedUrl] = useState("");
  const [saved, setSaved] = useState<SavedProfile | null>(null);
  const [activeGroup, setActiveGroup] = useState(0);
  const [showSource, setShowSource] = useState(false);
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [copied, setCopied] = useState("");
  const [origin, setOrigin] = useState("");
  const [dirty, setDirty] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [confirmRemoteDelete, setConfirmRemoteDelete] = useState(false);
  const [desktop, setDesktop] = useState(false);
  const [desktopReady, setDesktopReady] = useState(false);
  const [library, setLibrary] = useState<LibraryProfile[]>([]);
  const [loginItem, setLoginItem] = useState<{ enabled: boolean | null; pending: boolean; needsApproval: boolean; error: string }>({ enabled: null, pending: false, needsApproval: false, error: "" });
  const loginTimer = useRef<number | undefined>(undefined);
  const draftWrites = useRef<Promise<unknown>>(Promise.resolve());
  const draftTimer = useRef<number | undefined>(undefined);
  const pendingCopy = useRef("");
  const latency = useNodeLatency((nodes, signal) => {
    const chain = desktop ? profile.groups[activeGroup]?.chain : undefined;
    if (chain && !chain.entry) return Promise.reject(new Error("请先选择链式代理的前置节点。"));
    return api<PingResponse>("/api/ping", { sourceUrl: profile.sourceUrl.trim(), nodes, ...(chain ? { chainEntry: chain.entry } : {}) }, undefined, undefined, signal);
  });

  useEffect(() => {
    async function restore() {
      await Promise.resolve();
      setOrigin(window.location.origin);
      if (window.__SUBSCRIPTION_DESKTOP__) {
        setDesktop(true); setBusy("restore");
        try {
          const state = await api<DesktopState>("/api/desktop");
          setLibrary(state.profiles);
          let stored: Profile | null = null;
          if (state.current) {
            const data = await api<{ profile: Profile }>(`/api/profiles/${state.current.id}`, undefined, state.current.manageKey);
            stored = data.profile;
            setSaved({ ...state.current, subscriptionPath: subscriptionPath(stored.name, state.current.id, state.current.downloadKey) });
          }
          setProfile(state.draft ?? stored ?? freshProfile());
          setDirty(!!state.draft && JSON.stringify(state.draft) !== JSON.stringify(stored));
          if (state.draft || stored) setNotice("已恢复本机保存的订阅地址和配置；刷新源订阅可获取最新节点。");
          setDesktopReady(true);
        } catch (err) { setError(err instanceof Error ? err.message : "无法恢复本机配置"); }
        finally { setBusy(""); }
        return;
      }
      const hash = new URLSearchParams(window.location.hash.slice(1));
      const id = hash.get("id"), manageKey = hash.get("key"), downloadKey = hash.get("download");
      let existing: SavedProfile | null = null;
      try { existing = id && manageKey && downloadKey ? { id, manageKey, downloadKey, subscriptionPath: `/sub/${id}/${downloadKey}` } : JSON.parse(localStorage.getItem(STORAGE) ?? "null"); } catch { /* A new configuration replaces invalid local state. */ }
      if (!existing) return;
      setBusy("restore");
      try {
        const data = await api<{ profile: Profile }>(`/api/profiles/${existing.id}`, undefined, existing.manageKey);
        const canonical = { ...existing, subscriptionPath: subscriptionPath(data.profile.name, existing.id, existing.downloadKey) };
        setProfile(data.profile); setSaved(canonical);
        setNotice("已载入保存的配置；刷新源订阅即可查看最新节点。");
        localStorage.setItem(STORAGE, JSON.stringify(canonical));
      } catch (err) { setError(err instanceof Error ? err.message : "无法载入配置"); }
      finally { setBusy(""); }
    }
    void restore();
  }, []);

  useEffect(() => {
    if (!desktop || !desktopReady) return;
    function flush() {
      window.clearTimeout(draftTimer.current);
      const write = draftWrites.current.catch(() => undefined).then(() => api("/api/desktop/draft", { profile, current: saved }, undefined, "PUT"));
      draftWrites.current = write.catch((err) => { setError(err instanceof Error ? err.message : "本机配置保存失败"); });
      return write.then(() => undefined);
    }
    window.__flushSubscriptionDraft = flush;
    draftTimer.current = window.setTimeout(() => { void flush().catch(() => undefined); }, 250);
    return () => {
      window.clearTimeout(draftTimer.current);
      if (window.__flushSubscriptionDraft === flush) delete window.__flushSubscriptionDraft;
    };
  }, [desktop, desktopReady, profile, saved]);

  useEffect(() => {
    function result(event: Event) {
      const detail = (event as CustomEvent<{ ok: boolean; error?: string; action?: string; enabled?: boolean; needsApproval?: boolean }>).detail;
      if (["loginItem", "getLoginItem", "setLoginItem"].includes(detail?.action ?? "")) {
        window.clearTimeout(loginTimer.current);
        setLoginItem((previous) => ({ enabled: typeof detail.enabled === "boolean" ? detail.enabled : previous.enabled, pending: false, needsApproval: detail.needsApproval === true, error: detail.ok ? "" : detail.error || "无法读取或修改登录启动设置。" }));
        return;
      }
      if (!detail?.ok) setError(detail?.error || "系统操作失败，请重试。");
      else if (detail.action === "copy") { setCopied(pendingCopy.current); setTimeout(() => setCopied(""), 1800); }
      else if (detail.action === "importClash") setNotice("已发送至 Clash Party，请在 Clash Party 中确认导入。");
    }
    window.addEventListener("desktop-result", result);
    return () => window.removeEventListener("desktop-result", result);
  }, []);

  useEffect(() => {
    if (!desktop || !desktopReady) return;
    async function read() {
      await Promise.resolve();
      const bridge = window.webkit?.messageHandlers?.desktop;
      if (!bridge) { setLoginItem((previous) => ({ ...previous, error: "预览环境无法读取 macOS 登录设置。" })); return; }
      setLoginItem((previous) => ({ ...previous, pending: true, error: "" }));
      window.clearTimeout(loginTimer.current);
      loginTimer.current = window.setTimeout(() => { setLoginItem((previous) => ({ ...previous, pending: false, error: "读取登录启动设置超时，请重试。" })); }, 8000);
      bridge.postMessage({ action: "getLoginItem" });
    }
    void read();
    const onFocus = () => { void read(); };
    window.addEventListener("focus", onFocus);
    return () => { window.clearTimeout(loginTimer.current); window.removeEventListener("focus", onFocus); };
  }, [desktop, desktopReady]);

  function updateLoginItem(enabled?: boolean) {
    const bridge = window.webkit?.messageHandlers?.desktop;
    if (!bridge) { setLoginItem((previous) => ({ ...previous, error: "预览环境无法修改 macOS 登录设置。" })); return; }
    setLoginItem((previous) => ({ ...previous, pending: true, error: "" }));
    window.clearTimeout(loginTimer.current);
    loginTimer.current = window.setTimeout(() => { setLoginItem((previous) => ({ ...previous, pending: false, error: "操作超时，请重试读取系统状态。" })); }, 8000);
    bridge.postMessage(typeof enabled === "boolean" ? { action: "setLoginItem", enabled } : { action: "getLoginItem" });
  }

  async function refreshLibrary(updateSaved = false) {
    if (!desktop) return;
    const state = await api<DesktopState>("/api/desktop");
    setLibrary(state.profiles);
    if (updateSaved) setSaved((previous) => previous ? state.profiles.find((item) => item.id === previous.id) ?? previous : previous);
  }
  const remoteProfileId = desktop && saved?.remote ? saved.id : null;
  useEffect(() => {
    if (!remoteProfileId || busy) return;
    const controller = new AbortController();
    async function metadata() {
      try {
        const state = await api<DesktopState>("/api/desktop", undefined, undefined, undefined, controller.signal);
        if (controller.signal.aborted) return;
        setLibrary(state.profiles);
        const current = state.profiles.find((item) => item.id === remoteProfileId);
        if (current) setSaved((previous) => previous?.id === remoteProfileId ? { ...previous, remote: current.remote } : previous);
      } catch { /* Metadata polling does not affect saved configuration or downloads. */ }
    }
    const onFocus = () => { void metadata(); };
    window.addEventListener("focus", onFocus);
    const timer = window.setInterval(onFocus, 60_000);
    return () => { controller.abort(); window.clearInterval(timer); window.removeEventListener("focus", onFocus); };
  }, [remoteProfileId, busy]);

  async function syncRemote() {
    if (!desktop || !saved || dirty || busy) return;
    setBusy("remote-sync"); setError(""); setNotice("");
    try {
      await window.__flushSubscriptionDraft?.();
      const result = await api<{ remote: RemoteSubscription }>(`/api/profiles/${saved.id}/remote`, {}, saved.manageKey);
      setSaved((previous) => previous?.id === saved.id ? { ...previous, remote: result.remote } : previous);
      await refreshLibrary(true);
      setNotice(saved.remote ? "远程缓存已刷新，原远程地址继续有效。" : "远程订阅已生成，可复制给其他设备使用。");
    } catch (err) { setError(err instanceof Error ? err.message : "远程同步失败，请重试。"); }
    finally { setBusy(""); }
  }
  async function deleteRemote() {
    if (!desktop || !saved?.remote || busy || !confirmRemoteDelete) return;
    setBusy("remote-delete"); setError("");
    try {
      await window.__flushSubscriptionDraft?.();
      await api(`/api/profiles/${saved.id}/remote`, undefined, saved.manageKey, "DELETE");
      setSaved((previous) => { if (previous?.id !== saved.id) return previous; const next = { ...previous }; delete next.remote; return next; });
      setConfirmRemoteDelete(false);
      await refreshLibrary(true);
      setNotice("已停止远程分享，远程地址已失效。本机配置和本地地址保留。");
    } catch (err) { setError(err instanceof Error ? err.message : "无法停止远程分享，请重试。"); }
    finally { setBusy(""); }
  }
  async function selectSaved(id: string) {
    if (!id) { newProfile(); return; }
    const existing = library.find((item) => item.id === id);
    if (!existing) return;
    setBusy("restore"); setError("");
    window.clearTimeout(draftTimer.current);
    try {
      await draftWrites.current;
      const data = await api<{ profile: Profile }>(`/api/profiles/${id}`, undefined, existing.manageKey);
      latency.reset(); setProfile(data.profile); setSaved(existing); setInspection(null); setInspectedUrl(""); setActiveGroup(0); setDirty(false); setConfirmDelete(false); setConfirmRemoteDelete(false);
      setNotice("已载入本机保存的配置；刷新源订阅即可查看最新节点。");
    } catch (err) { setError(err instanceof Error ? err.message : "载入配置失败"); }
    finally { setBusy(""); }
  }
  function importClash(targetUrl = subscriptionUrl) {
    if (!saved || dirty || busy) return;
    const bridge = window.webkit?.messageHandlers?.desktop;
    if (!bridge) { setError("当前预览不支持打开 Clash Party，请复制订阅地址后手动导入。"); return; }
    const query = new URLSearchParams({ url: targetUrl, name: profile.name });
    bridge.postMessage({ action: "importClash", url: `clash://install-config?${query}` });
  }

  const currentGroup = profile.groups[activeGroup];
  const sourceReady = inspection && inspectedUrl === profile.sourceUrl.trim();
  const subscriptionUrl = saved ? `${origin}${saved.subscriptionPath}` : "";
  const missing = inspection ? profile.groups.flatMap((group) => [...group.nodes, ...(group.chain?.entry ? [group.chain.entry] : [])].filter((name) => !inspection.nodes.some((node) => node.name === name)).map((name) => `${group.name}：${name}`)) : [];

  function edit(next: Profile) { if (next.sourceUrl !== profile.sourceUrl) latency.reset(); setProfile(next); setDirty(true); setNotice(""); setError(""); }
  function updateGroup(index: number, next: Group) {
    const previous = profile.groups[index];
    if (index === activeGroup && (!!previous.chain !== !!next.chain || previous.chain?.entry !== next.chain?.entry)) latency.reset();
    const previousName = previous.name;
    edit({ ...profile, groups: profile.groups.map((group, i) => i === index ? next : group), rules: profile.rules.map((rule) => rule.group === previousName ? { ...rule, group: next.name } : rule) });
  }
  function removeGroup(index: number) {
    latency.reset();
    const name = profile.groups[index].name;
    edit({ ...profile, groups: profile.groups.filter((_, i) => i !== index), rules: profile.rules.filter((rule) => rule.group !== name) });
    setActiveGroup(Math.max(0, activeGroup >= index ? activeGroup - 1 : activeGroup));
  }
  function addGroup() {
    latency.reset();
    let number = profile.groups.length + 1;
    while (profile.groups.some((group) => group.name === `自定义组 ${number}`)) number++;
    edit({ ...profile, groups: [...profile.groups, { name: `自定义组 ${number}`, nodes: [] }] });
    setActiveGroup(profile.groups.length);
  }
  async function inspect() {
    latency.reset();
    setBusy("inspect"); setError(""); setNotice("");
    try {
      const url = profile.sourceUrl.trim();
      const data = await api<Inspection>("/api/inspect", { sourceUrl: url });
      setInspection(data); setInspectedUrl(url);
      if (!saved && !inspection && profile.name === "Claude 专属订阅") setProfile((previous) => ({ ...previous, name: `增强-${data.sourceName || "源订阅"}`.slice(0, 100).replace(/[\uD800-\uDBFF]$/, "") }));
      setNotice(`已实时拉取源订阅，共 ${data.nodes.length} 个节点。自定义组和规则已保留。`);
    } catch (err) { setError(err instanceof Error ? err.message : "源订阅解析失败"); }
    finally { setBusy(""); }
  }
  async function save() {
    setError(""); setNotice("");
    if (!profile.groups.length || profile.groups.some((group) => !group.name.trim() || !group.nodes.length)) { setError("请为每个代理组填写名称，并选择至少一个节点。"); return; }
    if (profile.groups.some((group) => group.chain && (!group.chain.entry || group.nodes.includes(group.chain.entry)))) { setError("链式代理需要选择前置节点，且前置节点不能同时作为出口节点。"); return; }
    if (new Set(profile.groups.map((group) => group.name.trim())).size !== profile.groups.length) { setError("代理组名称不能重复。"); return; }
    if (profile.rules.some((rule) => !rule.value.trim() || !profile.groups.some((group) => group.name === rule.group))) { setError("请填写规则匹配内容，并为每条规则选择代理组。"); return; }
    if (!profile.rules.length) { setError("请添加至少一条域名规则。"); return; }
    setBusy("save");
    window.clearTimeout(draftTimer.current);
    try {
      if (desktop) await draftWrites.current;
      const body = { ...profile, name: profile.name.trim(), sourceUrl: profile.sourceUrl.trim() };
      if (saved) {
        const result = await api<{ saved: true; remote?: RemoteSubscription }>(`/api/profiles/${saved.id}`, body, saved.manageKey, "PUT");
        const updated = { ...saved, ...(result.remote ? { remote: result.remote } : {}), subscriptionPath: subscriptionPath(body.name, saved.id, saved.downloadKey) };
        setSaved(updated); if (!desktop) localStorage.setItem(STORAGE, JSON.stringify(updated));
      }
      else {
        const result = await api<SavedProfile>("/api/profiles", body);
        setSaved(result); if (!desktop) localStorage.setItem(STORAGE, JSON.stringify(result));
      }
      setProfile(body);
      await refreshLibrary(true);
      setDirty(false);
      setNotice(saved ? "配置已更新，原订阅地址继续有效。" : "新订阅已生成。将下方地址导入 Clash 即可使用。");
    } catch (err) { setError(err instanceof Error ? err.message : "保存失败"); }
    finally { setBusy(""); }
  }
  async function copy(value: string, label: string) {
    try {
      const bridge = desktop && window.webkit?.messageHandlers?.desktop;
      if (bridge) { pendingCopy.current = label; bridge.postMessage({ action: "copy", text: value }); return; }
      await navigator.clipboard.writeText(value);
      setCopied(label); setTimeout(() => setCopied(""), 1800); }
    catch { setError("无法访问剪贴板，请手动选择并复制地址。"); }
  }
  function newProfile() {
    window.clearTimeout(draftTimer.current);
    latency.reset();
    setProfile(freshProfile()); setInspection(null); setSaved(null); setActiveGroup(0); setInspectedUrl(""); setDirty(false); setError(""); setNotice(""); setConfirmDelete(false); setConfirmRemoteDelete(false);
    if (!desktop) localStorage.removeItem(STORAGE); window.history.replaceState(null, "", "/");
  }
  async function deleteProfile() {
    if (!saved) return;
    setBusy("delete"); setError("");
    window.clearTimeout(draftTimer.current);
    try { await draftWrites.current; await api(`/api/profiles/${saved.id}`, undefined, saved.manageKey, "DELETE"); newProfile(); await refreshLibrary(); setNotice("配置已删除，旧订阅和管理地址已失效。"); }
    catch (err) { setError(err instanceof Error ? err.message : "删除失败"); }
    finally { setBusy(""); }
  }

  return <div className={`site-shell ${desktop ? "desktop-shell" : "web-shell"}`}>
    {!desktop && <aside className="web-sidebar">
      <a className="web-brand" href="#source-title" aria-label="cc助手首页"><span className="web-brand-icon"><GitBranch size={21} /></span><span>cc助手<small>网络配置助手</small></span></a>
      <div className="nav-caption">工作区</div>
      <nav aria-label="工作区导航"><a className="nav-active" href="#source-title"><GitBranch size={17} /><span>Clash 增强</span><span className="nav-active-dot" /></a></nav>
      <div className="nav-caption section-caption">当前配置</div>
      <nav className="section-navigation" aria-label="配置区导航"><a href="#source-title" title="源订阅"><Link2 size={16} />源订阅</a><a href="#groups-title" title="节点与链路"><Network size={16} />节点与链路</a><a href="#rules-title" title="域名规则"><ListFilter size={16} />域名规则</a><a href="#output-title" title="增强订阅"><FileCode2 size={16} />增强订阅</a></nav>
      <div className="sidebar-bottom"><span className="sidebar-privacy"><ShieldCheck size={15} />独立管理密钥</span><p>管理链接与订阅链接分开保存。</p><span className="sidebar-version">CC ASSISTANT</span></div>
    </aside>}
    <header className="topbar">{desktop ? <a className="brand" href={origin || "."} aria-label="cc助手首页"><span className="brand-mark"><GitBranch size={22} /></span><span>cc助手<small>CC ASSISTANT</small></span></a> : <div className="web-breadcrumb"><span>工作区</span><span className="breadcrumb-separator">/</span><strong>Clash 增强</strong></div>}<span className="topbar-note"><span className="status-dot" />{desktop ? "本机拉取 · 配置自动保存" : "源订阅实时更新"}</span></header>
    <main className="workspace">
      <div className="page-heading"><div><p className="eyebrow">订阅增强 · CLASH / MIHOMO</p><h1>{desktop ? "clash增强" : "Clash 增强"}</h1><p>{desktop ? "为指定域名选择固定节点，保留原订阅规则。" : "为指定域名配置独立节点，生成可自动更新的订阅。"}</p></div>{saved && !desktop && <button className="button secondary" onClick={newProfile} disabled={!!busy}><Plus size={16} />新建配置</button>}</div>
      {desktop && <div className="source-card desktop-library"><label className="field"><span className="input-label">本机保存的配置</span><select aria-label="本机保存的配置" value={saved?.id ?? ""} onChange={(event) => void selectSaved(event.target.value)} disabled={!!busy || !desktopReady}><option value="">新配置 / 未生成草稿</option>{library.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label><div className="desktop-login-item"><label><input type="checkbox" checked={loginItem.enabled === true} disabled={!desktopReady || loginItem.pending || loginItem.enabled === null} onChange={(event) => updateLoginItem(event.target.checked)} />登录时启动</label>{loginItem.pending && <small><LoaderCircle className="spin" size={12} />读取系统状态…</small>}{loginItem.needsApproval && <><small>需在系统设置中允许</small><button className="button text-button" onClick={() => window.webkit?.messageHandlers?.desktop?.postMessage({ action: "openLoginSettings" })}>打开登录项设置</button></>}{loginItem.error && <><small role="status">{loginItem.error}</small><button className="button text-button" onClick={() => updateLoginItem()} disabled={loginItem.pending}>重新读取</button></>}</div><button className="button secondary" onClick={newProfile} disabled={!!busy || !desktopReady}><Plus size={16} />新建配置</button></div>}
      <section className="source-card" aria-labelledby="source-title">
        <div className="section-head"><div className="step-heading"><span className="step-number">01</span><h2 id="source-title">源订阅</h2></div><span className="tag">实时拉取</span></div>
        <label className="input-label" htmlFor="source-url">订阅地址</label>
        <div className="source-form"><div className="secret-input"><Link2 size={18} /><input id="source-url" type={showSource ? "url" : "password"} value={profile.sourceUrl} onChange={(event) => edit({ ...profile, sourceUrl: event.target.value })} placeholder="https://example.com/subscribe?token=…" autoComplete="off" spellCheck={false} disabled={!!busy} onKeyDown={(event) => { if (event.key === "Enter" && profile.sourceUrl.trim()) void inspect(); }} /><button className="icon-button" aria-label={showSource ? "隐藏源订阅地址" : "显示源订阅地址"} onClick={() => setShowSource(!showSource)}>{showSource ? <EyeOff size={18} /> : <Eye size={18} />}</button></div><button className="button primary" onClick={inspect} disabled={!!busy || !profile.sourceUrl.trim()}>{busy === "inspect" ? <LoaderCircle className="spin" size={17} /> : inspection ? <RefreshCw size={17} /> : <ArrowDownToLine size={17} />}{busy === "inspect" ? "正在解析" : inspection ? "刷新源订阅" : "解析节点"}</button></div>
        <p className="helper">{desktop ? "订阅由本机拉取和解析；订阅地址、规则及选择的节点自动保存在本机。" : "支持包含节点的 Clash / Mihomo YAML 订阅。订阅内容由服务端解析，不上传到其他转换服务。"}</p>
        {sourceReady && <div className="source-summary"><span><Check size={15} />{inspection.nodes.length} 个节点 · {inspection.sourceGroups.length} 个原有代理组</span><span>本次拉取 {new Date(inspection.fetchedAt).toLocaleTimeString("zh-CN")}</span></div>}
      </section>
      {error && <div className="notice error" role="alert">{error}</div>}
      {notice && <div className="notice success" role="status"><Check size={17} />{notice}</div>}
      {missing.length > 0 && <div className="notice warning" role="alert">源订阅中已找不到所选节点：{missing.join("；")}。不会自动换用其他节点；含缺失节点的组将拒绝连接，请重新选择并保存。</div>}
      {inspection && !sourceReady && <div className="notice warning">源订阅地址已修改，请重新解析后选择节点。下方节点属于上一次拉取。</div>}
      <div className="editor-grid">
        <GroupEditor groups={profile.groups} nodes={sourceReady ? inspection.nodes : []} activeGroup={activeGroup} onSelect={(index) => { if (index !== activeGroup) latency.reset(); setActiveGroup(index); }} onAdd={addGroup} onRemove={removeGroup} onUpdate={updateGroup} disabled={!!busy} latency={latency} desktop={desktop} />
        <RuleEditor groups={profile.groups} rules={profile.rules} defaultGroup={currentGroup?.name ?? profile.groups[0]?.name ?? ""} onChange={(rules) => edit({ ...profile, rules })} disabled={!!busy} />
      </div>
      <section className="output-card" aria-labelledby="output-title">
        <div className="output-heading"><div className="step-heading"><span className="step-number">04</span><h2 id="output-title">生成增强订阅</h2></div><span className={`save-status ${dirty ? "unsaved" : ""}`}>{saved ? dirty ? "有未保存修改" : "配置已保存" : "尚未生成"}</span></div>
        <div className="save-form"><label className="field"><span className="input-label">增强订阅名称</span><input value={profile.name} onChange={(event) => edit({ ...profile, name: event.target.value })} placeholder="增强-原订阅名称" maxLength={100} disabled={!!busy} /></label><button className="button primary" onClick={save} disabled={!!busy || !sourceReady}>{busy === "save" ? <LoaderCircle className="spin" size={17} /> : saved ? <Check size={17} /> : <Link2 size={17} />}{busy === "save" ? "正在保存" : saved ? "保存修改" : "生成订阅地址"}</button></div>
        <p className="helper">保留原订阅名，加「增强-」前缀；未识别到原名可手动填写。</p>
        {!sourceReady && <p className="helper">先解析源订阅并选择节点，即可生成地址。</p>}
        {saved && <div className="generated-result">{desktop && dirty && <p className="helper">请先保存修改，再导入 Clash Party。</p>}<label className="input-label" htmlFor="subscription-output">{desktop ? "本机订阅地址" : "新订阅地址 · 导入 Clash / Mihomo"}</label><div className="copy-field"><input id="subscription-output" value={subscriptionUrl} readOnly spellCheck={false} onFocus={(event) => event.target.select()} /><button className="button secondary" onClick={() => copy(subscriptionUrl, "subscription")}>{copied === "subscription" ? <Check size={16} /> : <Copy size={16} />}{copied === "subscription" ? "已复制" : "复制地址"}</button>{desktop && <button className="button primary" onClick={() => importClash()} disabled={!!busy || dirty}><ArrowDownToLine size={16} />一键导入 Clash Party</button>}</div><p className="helper">{desktop ? "仅供本机使用，更新时需保持 cc助手运行。每次更新实时拉取源订阅，失败返回错误。" : "每次客户端拉取都会实时请求源订阅，再应用最新规则；源站暂时不可用时使用上次成功的原始源缓存，响应头标明缓存时间。"}</p><div className="result-actions">{!desktop && <><button className="button text-button" onClick={() => copy(`${origin}/#id=${saved.id}&key=${saved.manageKey}&download=${saved.downloadKey}`, "manage")}>{copied === "manage" ? <Check size={15} /> : <Copy size={15} />}{copied === "manage" ? "管理链接已复制" : "复制管理链接"}</button><span>管理链接可编辑配置，请单独保存并保密。</span></>}{!confirmDelete ? <button className="button text-button danger-text" onClick={() => setConfirmDelete(true)}>删除配置</button> : <div className="delete-confirm"><span>旧地址将立即失效。</span><button className="button text-button danger-text" onClick={deleteProfile} disabled={!!busy}>确认删除</button><button className="button text-button" onClick={() => setConfirmDelete(false)}>取消</button></div>}</div></div>}
      </section>
      {desktop && saved && <RemoteSubscriptionPanel remote={saved.remote} dirty={dirty} busy={busy} copied={copied === "remote"} confirmDelete={confirmRemoteDelete} onSync={() => void syncRemote()} onCopy={() => { if (saved.remote) void copy(saved.remote.subscriptionUrl, "remote"); }} onImport={() => { if (saved.remote) importClash(saved.remote.subscriptionUrl); }} onConfirmDelete={setConfirmRemoteDelete} onDelete={() => void deleteRemote()} />}
      <footer className="footer"><span><ShieldCheck size={16} />订阅和管理地址分别使用随机密钥，请勿公开分享。</span><span>固定节点的出口 IP 仍由节点服务商决定。</span></footer>
    </main>
  </div>;
}
