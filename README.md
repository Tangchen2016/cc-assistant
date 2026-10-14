# cc助手 · 自托管服务器版

源码位置：`/Users/skyblue/Mine/cc-assistant`。

网站和订阅处理接口运行在自己的 Node.js 服务器，无需 Cloudflare、D1 或 ChatGPT 托管。现有 macOS App 源码保留在 `desktop/`；已安装 App 暂不切换地址，等最终域名确定后再发布更新。

## 功能

- 解析 Clash / Mihomo YAML，保留源节点、代理组和规则。
- 美国节点优先显示，添加独立组、指定节点、域名规则与链式代理。
- 生成增强订阅 URL，名字保留并加前缀，下载和管理各用独立随机密钥。
- **每次下载先实时拉取源订阅，再应用当前保存的增强规则**。
- 拉取失败时使用最近成功的原始源 YAML；不是缓存最终成品。`X-Subscription-Source` 显示 `live` / `cache`，`X-Source-Updated-At` 显示源时间。新增配置没有成功源缓存时返回错误。
- App 上传原始缓存的兼容接口 `/api/remote-subscriptions`、`/remote-sub/...` 保留。
- 网站的延迟检测是 **服务器到节点的 TCP 连接延迟**，不是本机网络延迟或节点 HTTPS 代理成功证明。App 的独立 Mihomo HTTPS 检测保持原实现。
- SQLite 数据持久化，管理密钥仅存哈希。请求只接受公共网络源地址，每次重定向重新检查，并将校验后的 DNS 地址固定到实际连接。

当前支持内嵌 `proxies` 的 YAML；不支持 Base64 节点列表或只有 `proxy-providers` 的源配置。服务器 IP 可能仍被源站限制，这需要部署后实测；本机成功不代表 Vultr 一定成功。

## 本机运行

需要 Node.js **22.22.3 或以上 22.x** 与 npm：

```sh
npm ci
npm run dev
```

打开 `http://127.0.0.1:4175`。生产构建运行：

```sh
npm run build
npm start
```

默认数据在 `data/cc-assistant.sqlite`；可用 `DATABASE_PATH` 修改。目录不进入 Git，也不进入镜像。校验：`npm test`、`npm run typecheck`、`npm run lint`。生产构建后可运行 `npm run test:server`，验证真实 HTTP 路由、数据库重启和缓存回退。

## Vultr 部署（等待服务器准备完成）

建议 Ubuntu / Debian、Docker Engine 和 Compose 插件。NameSilo DNS 添加 `cc` 子域名的 A 记录指向 VPS；只有 IPv6 确认可用后才加 AAAA。开放入站 TCP 80/443，SSH 按服务器已有设置使用。应用 3000 端口只在容器网络开放。

把这份源码放到服务器 `/opt/cc-assistant`，在该目录运行：

```sh
cp .env.example .env
# 将 DOMAIN 改成实际域名，例如 cc.your-domain.com
# 只有域名和端口准备好后再启动
chmod 600 .env
docker compose config --quiet
docker compose up -d --build
docker compose ps
```

Caddy 自动申请并续期 HTTPS。`app_data` 保存 SQLite，`caddy_data` 保存证书。不要执行 `docker compose down -v`，它会删除数据卷。普通停止或重启不会删除配置。

验收：访问 `https://你的域名/api/health` 得到 `{"status":"ok"}`，再用实际源订阅测试解析、生成、下载、刷新与链式代理；最后通过手机或另一台电脑拉取增强 URL。**这些远程验收必须等服务器搭建完成再做，目前没有部署。**

## 备份与更新

```sh
./deploy/backup.sh
# 备份完成后更新源代码
# 更新前保留旧镜像标签，便于回退
docker compose build
docker compose up -d
```

备份使用 SQLite 在线备份接口，包含完整配置和订阅凭据，应私密保存。备份写入 `backups/`（Git 忽略），并设置 0600；拷贝备份后可删除容器 `/data/backup.sqlite`。恢复时先停止应用，在 app_data 卷中以备份替换数据库并清除旧 `-wal` / `-shm` 文件，再启动。回退代码不会回退数据库，恢复前需保留现有数据库副本。

应用不输出订阅内容或密钥，Caddy 未开启访问日志，避免 URL 中的读密钥进入日志。不要把管理链接、源订阅和数据库备份公开发送。健康检查不包含配置内容。

## 迁移边界

旧 Cloudflare 服务、D1 数据及已安装 App 在本次开发中保持现状。获得域名和服务器入口后，下一步是部署验收、迁移指定配置、让 App 指向自己的域名；新旧 URL 不会自动相同。验证通过后才停旧服务。
