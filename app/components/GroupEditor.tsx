"use client";

import { Check, Gauge, GitBranch, LoaderCircle, Plus, Search, Server, Trash2, X } from "lucide-react";
import { useState } from "react";
import type { Group, NodeSummary } from "../lib/types";
import { isUSNode, prioritizeNodes } from "../lib/node-region";
import type { LatencyState, NodeLatency } from "./useNodeLatency";

type Props = { groups: Group[]; nodes: NodeSummary[]; activeGroup: number; onSelect: (index: number) => void; onAdd: () => void; onRemove: (index: number) => void; onUpdate: (index: number, group: Group) => void; disabled: boolean; latency: LatencyState; desktop?: boolean };
function latencyLabel(result?: NodeLatency) {
  if (!result) return "未检测";
  if (result.status === "ok" && Number.isFinite(result.latencyMs)) return `${Math.max(1, Math.round(result.latencyMs!))} ms`;
  return { timeout: "超时", blocked: "已阻止", unavailable: "不可用", ok: "不可用" }[result.status];
}
export default function GroupEditor({ groups, nodes, activeGroup, onSelect, onAdd, onRemove, onUpdate, disabled, latency, desktop = false }: Props) {
  const [query, setQuery] = useState("");
  const [onlyUS, setOnlyUS] = useState(false);
  const current = groups[activeGroup];
  const chainEntry = current?.chain?.entry;
  const measurable = !desktop || !current?.chain || (!!chainEntry && nodes.some((node) => node.name === chainEntry) && !current.nodes.includes(chainEntry));
  const entryNodes = prioritizeNodes(nodes).filter((node) => !current?.nodes.includes(node.name));
  const usCount = nodes.filter((node) => isUSNode(node.name)).length;
  const visible = prioritizeNodes(nodes).filter((node) => (!onlyUS || isUSNode(node.name)) && node.name.toLocaleLowerCase().includes(query.toLocaleLowerCase()));
  function selection(names: string[]) { onUpdate(activeGroup, { ...current, nodes: names }); }
  function toggleChain(enabled: boolean) {
    const next = { ...current };
    if (enabled) next.chain = { entry: "" }; else delete next.chain;
    onUpdate(activeGroup, next);
  }
  return <section className="panel groups-panel" aria-labelledby="groups-title">
    <div className="section-head"><div className="step-heading"><span className="step-number">02</span><h2 id="groups-title">独立代理组</h2></div><button className="button text-button" onClick={onAdd} disabled={disabled}><Plus size={15} />添加组</button></div>
    <p className="section-description">选择具体节点，独立于原订阅的全局节点选择。</p>
    <div className="group-tabs" role="tablist" aria-label="代理组">{groups.map((group, index) => <button key={index} id={`group-tab-${index}`} role="tab" aria-selected={activeGroup === index} aria-controls="group-panel" className={`group-tab ${activeGroup === index ? "active" : ""}`} onClick={() => onSelect(index)}><GitBranch size={14} /><span>{group.name || "未命名组"}</span><small>{group.nodes.length}</small></button>)}</div>
    {current ? <div id="group-panel" role="tabpanel" aria-labelledby={`group-tab-${activeGroup}`}>
      <div className="group-title-form"><label className="field"><span className="input-label">代理组名称</span><input value={current.name} onChange={(event) => onUpdate(activeGroup, { ...current, name: event.target.value })} disabled={disabled} maxLength={80} /></label><button className="icon-button danger" aria-label={`删除代理组 ${current.name}`} onClick={() => onRemove(activeGroup)} disabled={disabled}><Trash2 size={17} /></button></div>
      {<div className="chain-settings"><label className="chain-toggle"><input type="checkbox" checked={!!current.chain} disabled={disabled} onChange={(event) => toggleChain(event.target.checked)} />启用链式代理</label>{current.chain && <><label className="field"><span className="input-label">前置节点</span><select aria-label="前置节点" value={current.chain.entry} onChange={(event) => onUpdate(activeGroup, { ...current, chain: { entry: event.target.value } })} disabled={disabled || !nodes.length}><option value="">请选择前置节点</option>{current.chain.entry && !entryNodes.some((node) => node.name === current.chain?.entry) && <option value={current.chain.entry} disabled>不可用：{current.chain.entry}</option>}{entryNodes.map((node) => <option key={node.name} value={node.name}>{node.name}</option>)}</select></label><p className="helper">本机 → 前置节点 → 出口节点 → 目标网站。目标网站看到的出口 IP 由最后的出口节点决定。</p>{!measurable && <p className="helper">先选择可用且不同于出口的前置节点，再检测链式路径。</p>}</>}</div>}
      <div className="node-picker-title"><span className="input-label">{current.chain ? "选择出口节点" : "选择节点"}</span><span>{current.nodes.length} 个已选</span></div>
      {current.nodes.length > 0 && <div className="selected-nodes">{current.nodes.map((name) => <button key={name} className={`node-chip ${nodes.length > 0 && !nodes.some((node) => node.name === name) ? "missing" : ""}`} aria-label={`移除所选节点 ${name}`} onClick={() => selection(current.nodes.filter((item) => item !== name))} disabled={disabled}><span>{name}</span><X size={12} /></button>)}</div>}
      <div className="node-region-filter"><span>美国节点优先 · {usCount} 个</span><label><input type="checkbox" checked={onlyUS} onChange={(event) => setOnlyUS(event.target.checked)} disabled={disabled || !nodes.length} />仅看美国</label></div>
      <label className="node-search"><Search size={16} /><span className="sr-only">搜索节点</span><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="搜索节点名称，例如 美国、US…" disabled={!nodes.length} /><span>{nodes.length}</span></label>
      <div className="latency-toolbar"><span>{desktop ? current.chain ? "链式延迟 · 前置→出口→测试网站" : "实际延迟 · 经节点访问测试网站" : "TCP 延迟 · 服务器→节点"}</span><button className="button text-button" onClick={() => void latency.check(visible.filter((node) => node.name !== chainEntry).map((node) => node.name))} disabled={disabled || !measurable || !!latency.progress || !visible.some((node) => node.name !== chainEntry)}>{latency.progress ? <LoaderCircle className="spin" size={13} /> : <Gauge size={13} />}{latency.progress ? `检测中 ${latency.progress.completed}/${latency.progress.total}` : "检测当前列表"}</button></div>
      {latency.error && <p className="latency-error" role="alert">{latency.error}</p>}
      <div className="node-list" aria-label="源订阅节点列表">{!nodes.length ? <div className="empty-state node-empty"><Server size={28} /><strong>你的节点会显示在这里</strong><p>先输入源订阅地址，点击「解析节点」。</p></div> : !visible.length ? <div className="empty-state"><p>{query ? `没有匹配“${query}”的${onlyUS ? "美国" : ""}节点。` : "没有按名称识别为美国的节点。"}</p></div> : visible.map((node) => {
        const checked = current.nodes.includes(node.name);
        const result = latency.results[node.name], pending = latency.pending.includes(node.name);
        return <div className={`node-row ${checked ? "selected" : ""}`} key={node.name}><label className="node-selection"><input type="checkbox" checked={checked} disabled={disabled || (node.name === chainEntry)} onChange={() => selection(checked ? current.nodes.filter((item) => item !== node.name) : [...current.nodes, node.name])} /><span className="node-check" aria-hidden="true">{checked && <Check size={13} />}</span><span className="node-name">{node.name}</span>{isUSNode(node.name) && <span className="node-region-badge">美国 · 名称识别</span>}<span className="node-type">{node.type.toUpperCase()}</span></label><span className={`node-latency ${result?.status === "ok" ? "ok" : result ? "failed" : ""}`} title={result?.error ?? (result?.measuredAt ? `${desktop ? current.chain ? `经前置节点 ${chainEntry} → 出口节点 ${node.name} HTTPS 请求 https://www.gstatic.com/generate_204` : "经所选节点 HTTPS 请求 https://www.gstatic.com/generate_204" : "云端 TCP 握手"} · ${new Date(result.measuredAt).toLocaleTimeString("zh-CN")}` : undefined)}>{pending ? <LoaderCircle className="spin" size={12} /> : latencyLabel(result)}</span><button className="icon-button node-ping" aria-label={`检测节点 ${node.name}`} onClick={() => void latency.check([node.name])} disabled={disabled || !measurable || !!latency.progress || (node.name === chainEntry)}><Gauge size={14} /></button></div>;
      })}</div>
      <p className="helper node-helper">按节点名称识别，实际出口以 IP 检测为准。选择 1 个节点固定线路；选择多个后可在该组内手动切换。</p>
      <p className="helper">{desktop ? "使用独立测试引擎，经每个节点请求 https://www.gstatic.com/generate_204，不携带登录 Cookie。结果衡量此次 HTTPS 请求延迟，不代表带宽或账号可用性。" : "延迟仅测服务器到节点的 TCP 连接，不验证链式代理；不代表本机或代理请求延迟。"}</p>
    </div> : <div className="empty-state"><GitBranch size={28} /><p>添加一个代理组，再选择固定节点。</p><button className="button secondary" onClick={onAdd}><Plus size={15} />添加代理组</button></div>}
  </section>;
}
