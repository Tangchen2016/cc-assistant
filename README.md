# cc助手 · 原生 Swift 客户端与自托管订阅服务

下文路径均相对于仓库根目录，命令也在仓库根目录执行。

macOS 2.0 客户端源码位于 `desktop/native/`，界面与本地业务全部由 Swift 实现。安装包不再包含 Node、React 或 WebView 页面。远程订阅继续由 Vultr 上的 Node 服务提供，入口为 `https://node.tangchen02.top`。原来的 Next.js 网站和 TypeScript 实现保留用于服务端及迁移对照。


## 原生客户端构建与迁移

- 构建：`python3 scripts/build-desktop.py`。需要完整 Xcode、SwiftPM、网络获取锁定的 Yams 6.2.2；首次构建下载依赖。无需 Node 来构建客户端。
- 产物：`outputs/desktop/cc助手.app` 与 `cc助手-macOS.zip`，同时包含 arm64 / x86_64，最低 macOS 14。开发签名，尚未公证。
- 主进程直接运行 SwiftUI 和 `Network.framework` 本机订阅监听器，仅绑定 `127.0.0.1:19473`；端口冲突只显示错误和重试入口，不退出整个 App。
- `profiles.json` 保持原 v1 格式和 id/manageKey/downloadKey，首次原生读取生成 `profiles.before-swift.json` 备份。损坏文件禁止覆盖。修改配置名称不会使原下载密钥失效。
- 本机订阅每次实时读取原订阅；远程同步沿用现有 HTTPS 协议和 15 分钟自动同步。远程服务器依旧支持源站失败时使用缓存。
- 节点测速由 Swift 调度独立 Mihomo 进程，使用临时 Unix socket 和私有配置，最多 4 路并发，不修改系统代理或 TUN。
- 测试：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-system native --scratch-path work/native-tests`。设置 `CC_SWIFT_PARITY_DIR` 可运行私密真实订阅对照；设置 `CC_SWIFT_REMOTE_VERIFY=1` 可验证自托管远程接口并自动清理测试记录。
- `desktop/src/` 与 `desktop/ui/` 是旧客户端实现，仅用于历史对照和回归测试，不再打包进 App。

## 功能

- 解析 Clash / Mihomo YAML，保留源节点、代理组和规则。
- 美国节点优先显示，添加独立组、指定节点、域名规则与链式代理。
- 指向自建固定出口的域名规则自动先拒绝 UDP，避免 TCP-only 出口被 QUIC 跳过后落入机场规则；浏览器通常回退 TCP。普通订阅节点组不添加此限制。
- 生成增强订阅 URL，名字保留并加前缀，下载和管理各用独立随机密钥。
- **每次下载先实时拉取源订阅，再应用当前保存的增强规则**。
- 拉取失败时使用最近成功的原始源 YAML；不是缓存最终成品。`X-Subscription-Source` 显示 `live` / `cache`，`X-Source-Updated-At` 显示源时间。新增配置没有成功源缓存时返回错误。
- App 上传原始缓存的兼容接口 `/api/remote-subscriptions`、`/remote-sub/...` 保留。
- 网站的延迟检测是 **服务器到节点的 TCP 连接延迟**，不是本机网络延迟或节点 HTTPS 代理成功证明。App 的独立 Mihomo HTTPS 检测保持原实现。
- SQLite 数据持久化，管理密钥仅存哈希。请求只接受公共网络源地址，每次重定向重新检查，并将校验后的 DNS 地址固定到实际连接。

当前支持内嵌 `proxies` 的 YAML；不支持 Base64 节点列表或只有 `proxy-providers` 的源配置。服务器 IP 可能仍被源站限制，实际源订阅在 VPS 的实时拉取仍需按服务商验证；本机成功不代表 Vultr 一定成功。

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

## 当前 Vultr 订阅接口

已部署到 `lax-node-01`，复用 `node.tangchen02.top` 的现有 HTTPS 入口。增强链接格式为 `/remote-sub/<id>/<下载密钥>/<名称>.yaml`，手机和电脑均可下载。每次下载尝试实时拉取源订阅，失败时使用最近保存的原始源缓存，再应用最新规则、链式代理和固定出口配置。

- 服务：`cc-assistant-subscriptions.service`，Node 22.22.3，监听 `127.0.0.1:19480`。
- 数据：`/var/lib/cc-assistant/cc-assistant.sqlite`，权限 0600。
- Nginx 仅转发订阅接口路径，原有 VLESS 路径保持可用。
- 构建：`node scripts/build-vps.mjs`；安装模板：`deploy/install-vps.sh`。
- 已验收公网 HTTPS 创建、下载、缓存回退、固定出口链路、密钥权限、重命名和测试数据清理；真实客户端发布接口亦通过。

## 完整网站的可选 Docker 部署

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

验收：访问 `https://你的域名/api/health` 得到 `{"status":"ok"}`，再用实际源订阅测试解析、生成、下载、刷新与链式代理；最后通过手机或另一台电脑拉取增强 URL。完整网站容器不是当前 VPS 的订阅微服务；Docker 运行仍未验收。

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

新版 App 新建远程订阅使用自己的域名。旧 Cloudflare 链接不会自动迁移或变成同一个 URL；已有旧记录仍按原服务处理，未自动停用旧服务。

## 客户端工作流（v2.0.0）

默认展示本机已保存的配置列表。新增配置依次完成：输入订阅并确认 → 选择 Claude 固定节点 / 链式代理并确认域名规则 → 确认名称和规则后生成地址。完成后可复制、导入 Clash Party 或返回列表；已有配置可编辑或直接查看地址。

网页版仍使用 React 和浏览器列表索引；macOS 客户端使用独立的原生 SwiftUI 页面与本机持久化配置。

## Claude 全生命周期菜单

客户端原生侧栏只有四个主菜单，没有子菜单：

1. 环境检测：默认显示出口 IP 检测及历史，通过“Clash 代理增强”按钮进入配置；链式代理是配置过程中的开关。
2. 账号注册：域名准备、Cloudflare 域名邮箱配置、独立注册浏览器。
3. 账号支付：在账号对应的独立浏览器中打开官方账单页，由用户本人完成。
4. 账号使用：沿用同一独立浏览器环境，并可以回到网络检测与配置。

注册环境保存在 `~/Library/Application Support/cc助手/registration/settings.json`（0600）。Chrome profile 使用其下 `chrome-profiles/<UUID>` 的私有目录；不复用日常 Chrome 或旧 CCBaga 资料目录。新建环境保留旧目录。直接使用本机已安装的 Google Chrome / Chromium，由 cc助手管理启动、窗口打开与关闭；不依赖 CCBaga 应用。启动机制参考本机 CCBaga v0.2.31 的 `src-tauri/src/browser/config.rs` 中独立 `user-data-dir` 和显式代理参数。

Cloudflare 邮件页面目前保存域名、目标邮箱和别名前缀，并检查公开 MX。真实 Email Routing 启用、目标邮箱验证、Catch-all 转发和测试收信在 Cloudflare 控制台由用户完成；检测到 MX 不表示这些步骤已完成。官方说明：https://developers.cloudflare.com/email-service/configuration/email-routing-addresses/

注册和支付页面只由用户主动打开；本次验收没有实际购买域名、修改 DNS、发送验证邮件、注册账号或付款。独立浏览器启动参数、目录隔离、私有持久化和输入边界通过 `tests/native/registration-check.swift` 验证，客户端界面已验收；CCBaga-B 空白页实际启动、独立资料目录和指定代理参数已核对，测试窗口已关闭。注册、邮件收信与支付尚未实际执行。

## 纯净浏览器出口检测

环境检测使用账号注册页同一浏览器引擎和当前代理配置（本机 Chrome / Chromium，运行与资料隔离由 cc助手负责）。以后台模式实际加载三个 `/cdn-cgi/trace` 页面，每次使用新建 0700 临时资料目录，完成后清理；不复用账号资料或登录 Cookie。启动参数与注册浏览器共用，包括显式代理、禁用 QUIC 和扩展。引擎缺失、配置无效或页面读取失败会报告失败，不用 WebKit 或 curl 替代结果。该结果用于验证所配置的浏览器网络路径，不证明已打开账号会话采用了最新设置；耗时包含启动。

### macOS DMG 与更新

运行 `python3 scripts/build-desktop.py`，生成 `outputs/desktop/cc助手-macOS.dmg`，支持 Apple Silicon 和 Intel（macOS 14+）。首次拖入 Applications 安装，2.0.1 起可通过菜单栏「cc助手 → 检查更新…」下载安装并重启。旧版首次需手动替换。签名、公证限制和后续发布步骤见 [桌面更新说明](docs/desktop-updates.md)。
