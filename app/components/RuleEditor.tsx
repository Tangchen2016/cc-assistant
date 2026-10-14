"use client";

import { ArrowRight, ChevronDown, Plus, ShieldCheck, Trash2 } from "lucide-react";
import type { Group, Rule } from "../lib/types";

export default function RuleEditor({ groups, rules, defaultGroup, onChange, disabled }: { groups: Group[]; rules: Rule[]; defaultGroup: string; onChange: (rules: Rule[]) => void; disabled: boolean }) {
  function update(index: number, next: Rule) { onChange(rules.map((rule, i) => i === index ? next : rule)); }
  return <section className="panel rules-panel" aria-labelledby="rules-title">
    <div className="section-head"><div className="step-heading"><span className="step-number">03</span><h2 id="rules-title">域名转发规则</h2></div><span className="tag muted">优先匹配</span></div>
    <p className="section-description">这些规则会放在源订阅规则之前，原有规则继续保留。</p>
    <div className="rule-table"><div className="rule-table-head"><span>匹配方式 / 域名</span><span>转发到</span></div>{rules.map((rule, index) => <div className="rule-row" key={index}><div className="rule-match"><label className="select-wrap"><span className="sr-only">第 {index + 1} 条规则匹配方式</span><select value={rule.type} onChange={(event) => update(index, { ...rule, type: event.target.value as Rule["type"] })} disabled={disabled}><option value="DOMAIN-SUFFIX">域名后缀</option><option value="DOMAIN">完整域名</option><option value="DOMAIN-KEYWORD">域名关键词</option></select><ChevronDown size={12} /></label><input aria-label={`第 ${index + 1} 条规则域名`} value={rule.value} onChange={(event) => update(index, { ...rule, value: event.target.value })} placeholder="example.com" spellCheck={false} disabled={disabled} /></div><ArrowRight className="rule-arrow" size={16} /><label className="select-wrap target-select"><span className="sr-only">第 {index + 1} 条规则代理组</span><select value={rule.group} onChange={(event) => update(index, { ...rule, group: event.target.value })} disabled={disabled}>{groups.map((group, i) => <option value={group.name} key={i}>{group.name || "未命名组"}</option>)}</select><ChevronDown size={12} /></label><button className="icon-button danger" aria-label={`删除规则 ${rule.value || index + 1}`} onClick={() => onChange(rules.filter((_, i) => i !== index))} disabled={disabled}><Trash2 size={15} /></button></div>)}</div>
    <button className="add-rule" onClick={() => onChange([...rules, { type: "DOMAIN-SUFFIX", value: "", group: defaultGroup }])} disabled={disabled || !groups.length}><Plus size={16} />添加域名规则</button>
    <div className="rule-info"><ShieldCheck size={18} /><p>客户端使用<strong>规则模式</strong>，才能按域名分流。</p></div>
  </section>;
}
