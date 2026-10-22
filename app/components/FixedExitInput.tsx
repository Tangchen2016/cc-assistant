"use client";

import { Check, Copy, Eye, EyeOff } from "lucide-react";
import { useState } from "react";

type Props = { value: string; disabled: boolean; copied: boolean; onChange: (value: string) => void; onCopy: () => void };
export default function FixedExitInput({ value, disabled, copied, onChange, onCopy }: Props) {
  const [visible, setVisible] = useState(false);
  return <div className="field">
    <label className="input-label" htmlFor="fixed-exit-link">固定出口分享链接</label>
    <div className="secret-input">
      <input id="fixed-exit-link" aria-label="固定出口分享链接" type={visible ? "text" : "password"} autoComplete="off" spellCheck={false} value={value} placeholder="vless://…（WebSocket + TLS）" disabled={disabled} onChange={event => onChange(event.target.value.trim())} />
      <button type="button" className="icon-button" aria-label={visible ? "隐藏固定出口链接" : "显示固定出口链接"} title={visible ? "隐藏链接" : "显示链接"} aria-pressed={visible} disabled={disabled || !value} onClick={() => setVisible(v => !v)}>{visible ? <EyeOff size={16} /> : <Eye size={16} />}</button>
      <button type="button" className="icon-button" aria-label={copied ? "固定出口链接已复制" : "复制固定出口链接"} title={copied ? "已复制" : "复制链接"} disabled={disabled || !value} onClick={onCopy}>{copied ? <Check size={16} /> : <Copy size={16} />}</button>
    </div>
    {copied && <span className="helper" role="status">固定出口链接已复制</span>}
  </div>;
}
