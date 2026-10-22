# cc助手项目部署与发布

本文是项目发布的统一入口。所有本地命令在仓库根目录执行；“服务器执行”指已确认的目标服务器。本文依据仓库脚本整理，不代表当前线上版本已经核验。

## 1. 先选择发布对象

| 对象 | 源码 / 构建入口 | 部署位置 / 入口 |
| --- | --- | --- |
| 官网、手机检测、导入向导、网页号池 | `website/`，静态文件，无需 Next.js 构建 | `/var/www/cc-assistant-site/` → `https://tangchen02.top/apps/cc-assistant/` |
| 个人主页、博客、应用目录 | `personal-site/` | `/var/www/tangchen-site/`，与 cc助手网页分开发布 |
| 远程订阅服务 | `server/vps-service.ts` → `node scripts/build-vps.mjs` | `/opt/cc-assistant/current/server.mjs`，systemd，127.0.0.1:19480 |
| macOS App | `desktop/native/` → `python3 scripts/build-desktop.py` | 本机安装；正式更新发布到 `/var/www/cc-assistant-updates/` |
| 邮件辅助 Worker | `cloud/mail-assistant/` | Cloudflare，独立授权、配置与发布 |
| 完整 Next.js 网站（可选方案） | `app/`、`compose.yaml` | Docker + Caddy，不是当前静态官网 |
| iOS 原生工程 | `ios/` | Xcode 构建和签名，不通过 Nginx 发布 |

仅改检测网页时，只发布 `website/`。不要顺带替换 App、邮件 Worker、订阅服务或个人主页。

## 2. 发布前确认

1. 查看 `git status --short`，明确本次变更及产物；工作区可能有其他未完成改动，不能直接全目录上传。
2. 确认 SSH 目标、目标目录、当前版本和备份位置。SSH 别名由操作者按实际环境填写，不默认使用某个私人别名。
3. 不上传 `.env`、`data/`、`work/`、用户配置、签名私钥、订阅密钥或邮件凭据。
4. 检查对应功能，而不只检查构建通过。涉及真实账号或发送邮件的验收必须另行明确授权。
5. 保留上个可用产物。服务启动成功、HTTP 200 和真实业务验收分别记录。

## 3. 静态网页发布（最常用）

### 本地预览

页面使用 `/apps/cc-assistant/` 绝对前缀，不能简单以 `website/` 为根预览。创建临时站点根目录：

```sh
preview_dir=$(mktemp -d /tmp/cc-site-preview.XXXXXX)
mkdir -p "$preview_dir/apps"
ln -s "$PWD/website" "$preview_dir/apps/cc-assistant"
python3 -m http.server 8088 --bind 127.0.0.1 --directory "$preview_dir"
```

访问 `http://127.0.0.1:8088/apps/cc-assistant/`，检查首页、`check/`、`import/`、`accounts/` 的实际改动。Ctrl+C 停止预览。该服务器不模拟生产 CSP 和 HTTPS，跨域检测最终仍需在线验收。

### 备份和上传

下面 `<服务器SSH目标>` 必须替换；SSH 用户需有目标目录的写权限。使用新的时间戳，禁止覆盖旧备份。

```sh
DEPLOY_HOST='<服务器SSH目标>'
release_stamp=$(date -u +%Y%m%dT%H%M%SZ)
ssh "$DEPLOY_HOST" "cp -a /var/www/cc-assistant-site /var/www/cc-assistant-site.backup-$release_stamp"
rsync -av --dry-run website/ "$DEPLOY_HOST:/var/www/cc-assistant-site/"
# 确认 dry-run 只有本次静态文件后上传
rsync -av website/ "$DEPLOY_HOST:/var/www/cc-assistant-site/"
```

这是就地上传，不是原子发布；多文件不兼容改动应安排维护窗口或另做版本目录切换。这里故意不使用 `--delete`，需要删除的过期文件逐项确认。首次部署需先创建目标目录、安装 Nginx 站点和证书；不要把更新命令当首次安装脚本。

纯文件更新不需要重启 Nginx。仅当修改 `deploy/nginx-website.conf` 时，备份线上配置，核对生产自定义内容后更新 `/etc/nginx/sites-available/cc-website`，再在服务器执行：

```sh
sudo nginx -t
# 仅上一条成功后执行
sudo systemctl reload nginx
```

不要覆盖 `node.tangchen02.top` 的订阅、更新和节点路由。

### 发布验证

```sh
curl --fail --silent --show-error -o /dev/null https://tangchen02.top/apps/cc-assistant/
curl --fail --silent --show-error -o /dev/null https://tangchen02.top/apps/cc-assistant/check/
```

还需在浏览器验证本次改动、JS/CSS 无 404、控制台无新增错误、手机宽度和实际交互。检查下载版本与已发布安装包一致；不要使用文档中的历史版本号。若有 Cloudflare 缓存，确认响应确实是新文件，必要时只清理变更 URL 的缓存。

检测必须由用户浏览器访问检测目标；不能改为服务器代查，否则显示的是服务器出口。

### 回退

将发布前的 `cc-assistant-site.backup-<时间戳>/` 内容恢复到站点目录。恢复时先核对差异，清除本次新增且不属于旧版本的文件，防止混合版本。Nginx 配置若改过，一并恢复对应备份、`nginx -t` 后重载，再验证页面。**删除站点链接是下线，不是版本回退。**

## 4. 远程订阅服务

本地构建、测试：

```sh
npm ci
npm test
node scripts/build-vps.mjs
```

产物为 `dist/vps/server.mjs`。脚本依赖 `esbuild`；若安装后找不到，应先修复构建依赖，不能上传旧产物充数。

现有安装脚本 `deploy/install-vps.sh <服务器上传目录>` 要求该目录包含：

- `server.mjs`
- `node-v22.22.3-linux-x64.tar.xz` 和匹配的官方 `SHASUMS256.txt`
- `cc-assistant-subscriptions.service`
- `nginx-subscriptions.conf`

运行前备份数据库（SQLite 在线备份或停服务后一致性备份）、记录 `/opt/cc-assistant/current` 的旧目标，并备份 systemd/Nginx 配置。脚本会安装运行时、切换 current、重启服务及重载 Nginx，需服务器管理权限。它不是原子事务；健康检查失败不会自动回退 current 或数据库。

验证：

```sh
# 服务器执行
systemctl is-active cc-assistant-subscriptions
curl --fail http://127.0.0.1:19480/api/health
# 本地执行
curl --fail https://node.tangchen02.top/api/health
```

随后验证增强订阅下载、缓存回退和本次功能；密钥 URL 不写日志或发布记录。数据库在 `/var/lib/cc-assistant/cc-assistant.sqlite`。

回退：恢复旧 current 目标和本次改动的配置，重启订阅服务、检查健康；必要时恢复匹配版本的数据库备份。数据库恢复前先保存故障现场。不要修改同机 Xray/VLESS 路由。

## 5. macOS 构建与正式更新

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-system native --scratch-path work/native-tests
python3 scripts/build-desktop.py
```

产物：`outputs/desktop/cc助手.app`、ZIP、DMG。构建脚本根据 `CODESIGN_IDENTITY` 或本机 `config/signing.local.json` 选择签名，没有配置时使用 ad-hoc。开发签名和 Sparkle 签名均不等于 Apple Developer ID 公证。

本机验收通过、明确准备正式发布后：

1. 增加 `desktop/native/Info.plist` 的版本与构建号，重新构建并验证。
2. 执行 `python3 scripts/prepare-update.py`，生成 `outputs/updates/` 版本化 DMG 与签名 appcast。
3. 先上传新 DMG 到 `/var/www/cc-assistant-updates/`，核对公网可下载及 SHA256。
4. 最后在同一文件系统内原子替换 `appcast.xml`，更新官网版本及下载信息。
5. 从旧版实际更新，检查安装、重启、版本与原有配置保留。仅 HTTP 200 不算升级验收。

回退更新清单只能停止向旧客户端提供坏版本，不能自动降级已经安装的用户。已安装用户应发布更高构建号的修复版，或指导手动恢复已验证旧包。

详细密钥与更新入口见 [桌面更新说明](desktop-updates.md)。签名私钥绝不上传服务器。

## 6. 其他部署

- 邮件辅助：按 [邮件辅助说明](mail-assistant.md) 操作。Worker 发布和 Email Routing 修改分开验证；失败时恢复原邮件转发规则。
- 完整 Next.js：按 [README 的 Docker 方案](../README.md#完整网站的可选-docker-部署) 操作。它会占用 80/443，不要在当前 Nginx 主机直接启动造成端口冲突；不得 `docker compose down -v`。
- 小火箭导入属于使用说明，见 [小火箭 Claude 专项扩展](shadowrocket-usage.md)，不是网页发布步骤。

## 7. 发布记录

每次记录：变更范围、源码提交或工作区差异、构建结果、目标服务器/目录、产物版本和 SHA256、备份路径、线上检查、真实业务验收、已知未完成项。未验证的功能明确标记，不以“发布成功”代替全流程可用。
