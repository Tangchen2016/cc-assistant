import { UserError } from "./errors.ts";
import { validateSourceUrl } from "./source-validation.ts";

/** Fixed-exit front that tests every source node instead of following a named source group. */
export const AUTO_CHAIN_ENTRY = "*";

// Only import the transport we support; never pass arbitrary share-link fields through.
export function parseFixedExitLink(input: unknown) {
  try {
    if (typeof input !== "string" || input.length > 4096 || /[\x00-\x20\x7f]/.test(input)) throw new Error();
    const url = new URL(input);
    if (url.protocol !== "vless:" || url.password || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(url.username) || url.pathname && url.pathname !== "/") throw new Error();
    const params = url.searchParams;
    const allowed = new Set(["type", "security", "encryption", "sni", "host", "path", "fp", "alpn"]);
    for (const key of params.keys()) if (!allowed.has(key) || params.getAll(key).length !== 1) throw new Error();
    if (params.get("type") !== "ws" || params.get("security") !== "tls" || params.has("encryption") && params.get("encryption") !== "none") throw new Error();
    const publicHost = (value: string) => {
      if (!value || /[\s/@?#\\]/.test(value)) throw new Error();
      const checked = validateSourceUrl(`https://${value}`);
      if (checked.port || checked.hostname !== value.toLowerCase()) throw new Error();
      return value;
    };
    const server = publicHost(url.hostname);
    const servername = publicHost(params.get("sni") ?? server);
    const host = publicHost(params.get("host") ?? servername);
    const path = params.get("path") ?? "/";
    if (!path.startsWith("/") || /[\x00-\x20\x7f]/.test(path)) throw new Error();
    const port = Number(url.port || 443);
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error();
    const fingerprint = params.get("fp");
    if (fingerprint && !["chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"].includes(fingerprint)) throw new Error();
    const alpn = params.get("alpn")?.split(",");
    if (alpn && alpn.some((item) => !["http/1.1", "h2"].includes(item))) throw new Error();
    return {
      type: "vless", server, port, uuid: url.username, tls: true, servername, network: "ws",
      "ws-opts": { path, headers: { Host: host } },
      ...(fingerprint ? { "client-fingerprint": fingerprint } : {}), ...(alpn ? { alpn } : {}),
    };
  } catch {
    throw new UserError("固定出口链接无效：请使用公共地址、有效 UUID 和安全的 VLESS + WebSocket + TLS 分享链接。", 422);
  }
}
