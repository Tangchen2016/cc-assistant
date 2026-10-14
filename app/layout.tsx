import type { Metadata } from "next";
import "./globals.css";
import "./workspace.css";

export const metadata: Metadata = {
  title: "cc助手 · Clash 增强",
  description: "为 Clash / Mihomo 订阅添加独立代理组和域名规则，每次拉取增强订阅时实时更新源订阅。",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      <body className="antialiased">{children}</body>
    </html>
  );
}
