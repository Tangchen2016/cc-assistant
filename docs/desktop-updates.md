# macOS 安装与更新

首次安装：打开 `cc助手-macOS.dmg`，将 cc助手拖入 Applications。旧版 1.x / 2.0.0 没有更新器，需要先退出并手动替换一次；配置仍在用户 Application Support 目录内。

2.0.1 起：菜单栏「cc助手 → 检查更新…」，发现新版后按提示下载安装并重启。使用 Sparkle 2.10.0，HTTPS 下载、Ed25519 签名验证后才解压安装。默认不后台检查。

发布步骤：

1. 同时增加 `desktop/native/Info.plist` 的显示版本和构建号。
2. `python3 scripts/build-desktop.py` 构建双架构 App、ZIP 和 DMG。
3. `python3 scripts/prepare-update.py` 生成版本化 DMG 和签名 appcast。
4. 将新 DMG 上传到服务器 `/var/www/cc-assistant-updates/`；最后原子替换 `appcast.xml`，避免先发布不存在的下载地址。
5. 从旧版完成实际下载、安装和重启验证，确认用户配置与本地服务保留。

签名私钥只保存在这台 Mac 登录钥匙串，账户名 `cc-assistant-updates`；不要上传到服务器或提交源码。换电脑前用 Sparkle 官方 generate_keys 工具妥善备份与迁移。

更新入口：`https://node.tangchen02.top/updates/appcast.xml`。Nginx 使用 `deploy/nginx-updates.conf`，与订阅接口及 VLESS 路由分开。

当前 App 为 ad-hoc 签名，尚未取得 Apple Developer ID 签名与公证。Sparkle 更新签名不等于 Apple 公证；首次安装仍可能遇到 macOS 来源验证提示。
