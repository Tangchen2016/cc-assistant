"use client";

import { ArrowDownToLine, Check, Copy, Link2, LoaderCircle, RefreshCw } from "lucide-react";
import type { RemoteSubscription } from "../lib/types";

type Props = {
  remote?: RemoteSubscription;
  dirty: boolean;
  busy: string;
  copied: boolean;
  confirmDelete: boolean;
  onSync: () => void;
  onCopy: () => void;
  onImport: () => void;
  onConfirmDelete: (confirmed: boolean) => void;
  onDelete: () => void;
};

export default function RemoteSubscriptionPanel({ remote, dirty, busy, copied, confirmDelete, onSync, onCopy, onImport, onConfirmDelete, onDelete }: Props) {
  const time = remote ? new Date(remote.updatedAt) : null;
  return <section className="remote-subscription" aria-labelledby="remote-subscription-title">
    <div className="section-head"><div><h2 id="remote-subscription-title">远程订阅</h2><p className="helper">其他设备可使用；Mac 离线时仍可下载云端缓存。</p></div><button className="button primary" onClick={onSync} disabled={!!busy || dirty}>{busy === "remote-sync" ? <LoaderCircle className="spin" size={16} /> : remote ? <RefreshCw size={16} /> : <Link2 size={16} />}{busy === "remote-sync" ? "正在同步" : remote ? "刷新远程缓存" : "生成远程订阅地址"}</button></div>
    {dirty && <p className="helper">请先保存修改，再生成或刷新远程订阅。</p>}
    {remote && <>
      <label className="input-label" htmlFor="remote-subscription-output">远程订阅地址</label><div className="copy-field"><input id="remote-subscription-output" value={remote.subscriptionUrl} readOnly spellCheck={false} onFocus={(event) => event.target.select()} /><button className="button secondary" onClick={onCopy} disabled={!!busy}>{copied ? <Check size={16} /> : <Copy size={16} />}{copied ? "已复制" : "复制远程地址"}</button></div>
      <p className="helper">最近缓存：{time && Number.isFinite(time.getTime()) ? time.toLocaleString("zh-CN") : "时间未知"}</p>
      {remote.lastError && <div className="notice warning" role="status">最近一次同步失败，远程地址仍可使用此前缓存。请稍后刷新。</div>}
      <div className="result-actions"><button className="button secondary" onClick={onImport} disabled={!!busy || dirty}><ArrowDownToLine size={16} />一键导入远程地址</button>{!confirmDelete ? <button className="button text-button danger-text" onClick={() => onConfirmDelete(true)} disabled={!!busy}>停止远程分享</button> : <div className="delete-confirm"><span>远程地址将失效，本机配置保留。</span><button className="button text-button danger-text" onClick={onDelete} disabled={!!busy}>{busy === "remote-delete" ? "正在停止" : "确认停止"}</button><button className="button text-button" onClick={() => onConfirmDelete(false)} disabled={!!busy}>取消</button></div>}</div>
    </>}
    <p className="helper">远程请求时尝试拉取源订阅并执行增强规则；源站不可用时使用最近缓存。App 在线每 15 分钟同步，Mac 离线仍可下载缓存。</p>
    <p className="helper">远程地址包含访问密钥，可下载你的节点配置，请仅分享给可信设备。</p>
  </section>;
}
