"use client";

import { BookOpen, Check, Copy, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { staticProxyGuide } from "../lib/static-proxy-guide";

export default function StaticProxyGuide() {
  const [open, setOpen] = useState(false);
  const [status, setStatus] = useState("");
  const [copying, setCopying] = useState(false);
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    if (!open) return;
    dialog.current?.showModal();
    function result(event: Event) {
      const detail = (event as CustomEvent).detail;
      if (detail?.action !== "copy") return;
      setCopying(false);
      setStatus(detail.ok ? "已复制完整说明" : "复制失败，请在下方选中文本手动复制。");
    }
    window.addEventListener("desktop-result", result);
    return () => window.removeEventListener("desktop-result", result);
  }, [open]);
  async function copy() {
    setStatus("");
    setCopying(true);
    try {
      const bridge = window.webkit?.messageHandlers?.desktop;
      if (bridge) { bridge.postMessage({ action: "copy", text: staticProxyGuide }); return; }
      await navigator.clipboard.writeText(staticProxyGuide);
      setStatus("已复制完整说明");
    } catch { setStatus("复制失败，请在下方选中文本手动复制。"); }
    setCopying(false);
  }
  return <>
    <button type="button" className="button secondary static-guide-trigger" onClick={() => { setStatus(""); setCopying(false); setOpen(true); }}><BookOpen size={15} />用 AI 部署静态代理</button>
    {open && <dialog ref={dialog} className="static-guide-dialog" aria-labelledby="static-guide-title" onCancel={() => setOpen(false)} onClose={() => setOpen(false)}>
      <header><div><h2 id="static-guide-title">静态代理部署说明</h2><p>复制给本地 AI，让它准备固定出口并交付可直接填入 cc助手的完整链接。</p></div><button type="button" className="icon-button" aria-label="关闭部署说明" onClick={() => setOpen(false)}><X size={19} /></button></header>
      <p className="static-guide-scope">未提供服务器登录信息时，AI 会先询问；完成后必须给出经过验证、可直接粘贴的完整 URL。</p>
      <textarea aria-label="完整 AI 部署说明" value={staticProxyGuide} readOnly spellCheck={false} />
      <footer><span role="status">{status}</span><button type="button" className="button primary" disabled={copying} onClick={() => void copy()}>{status === "已复制完整说明" ? <Check size={15} /> : <Copy size={15} />}{copying ? "复制中…" : "复制完整说明"}</button></footer>
    </dialog>}
  </>;
}
