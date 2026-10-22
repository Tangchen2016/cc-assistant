import ipaddr from "ipaddr.js";
import { UserError } from "./errors.ts";

export function isPublicAddress(address: string) {
  try { return ipaddr.process(address).range() === "unicast"; }
  catch { return false; }
}

export function validateSourceUrl(value: unknown) {
  if (typeof value !== "string" || value.length > 4096) throw new UserError("请输入有效的源订阅地址。");
  let url: URL;
  try { url = new URL(value); } catch { throw new UserError("请输入完整的 HTTP / HTTPS 订阅地址。"); }
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.hash) {
    throw new UserError("仅支持不含账号密码和片段的 HTTP / HTTPS 订阅地址。");
  }
  const host = url.hostname.replace(/^\[|\]$/g, "").toLowerCase().replace(/\.$/, "");
  if (!host || host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal") || !host.includes("." ) && !host.includes(":")) {
    throw new UserError("订阅地址必须指向公共网络。");
  }
  if (ipaddr.isValid(host) && !isPublicAddress(host)) throw new UserError("禁止访问本机、内网或特殊用途地址。");
  return url;
}

