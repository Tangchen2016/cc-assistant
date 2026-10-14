import { NextResponse, type NextRequest } from "next/server";
const limits = new Map<string, { count: number; until: number }>();
export function proxy(request: NextRequest) {
  if (!["POST", "PUT", "DELETE", "PATCH"].includes(request.method)) return NextResponse.next();
  const origin = request.headers.get("origin");
  const expected = process.env.PUBLIC_ORIGIN || new URL(request.url).origin;
  if (origin && origin !== expected || request.headers.get("sec-fetch-site") === "cross-site") return NextResponse.json({ error: "拒绝跨站写入。" }, { status: 403 });
  if (!(request.headers.get("content-type") ?? "").startsWith("application/json") && request.method !== "DELETE") return NextResponse.json({ error: "请求必须为 JSON。" }, { status: 415 });
  // Trust X-Forwarded-For only when the app is behind the bundled Caddy proxy.
  const ip = process.env.TRUST_PROXY === "1" ? request.headers.get("x-forwarded-for")?.split(",").at(-1)?.trim() ?? "unknown" : "local";
  const now = Date.now();
  for (const [key, row] of limits) if (row.until <= now) limits.delete(key);
  if (!limits.has(ip) && limits.size >= 4096) return NextResponse.json({ error: "请求过多，请稍后重试。" }, { status: 429 });
  const row = limits.get(ip) ?? { count: 0, until: now + 60_000 };
  row.count++; limits.set(ip, row);
  if (row.count > 60) return NextResponse.json({ error: "请求过多，请稍后重试。" }, { status: 429, headers: { "Retry-After": "60" } });
  return NextResponse.next();
}
export const config = { matcher: "/api/:path*" };
