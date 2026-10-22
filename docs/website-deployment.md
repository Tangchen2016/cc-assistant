# 官网部署配置

完整发布、验证和回退流程见 [项目部署与发布](deployment.md)。

- 主入口：https://tangchen02.top/apps/cc-assistant/
- www 保留路径跳转到主域名；根路径为个人主页，博客位于 /blog/，软件下载位于 /apps/。
- 源码：website/，纯静态 HTML/CSS，无第三方脚本。所有资源与站内首页链接均使用 /apps/cc-assistant/ 前缀。
- 服务器目录：/var/www/cc-assistant-site/
- Nginx：deploy/nginx-website.conf，安装为 /etc/nginx/sites-available/cc-website。
- node 子域名保持原有订阅、更新和节点路由。

## 更新页面

仅发布 website/ 内的静态文件，不上传项目目录或用户配置。发布新版后同时更新下载链接、版本和大小说明，以实际已发布的安装包为准。

## HTTPS

根域名与 www 使用独立 Let's Encrypt 证书，位于 /etc/letsencrypt/live/tangchen02.top/。certbot.timer 自动续期，renewal-hooks/deploy/reload-nginx 校验配置后重载 Nginx。

80 端口只允许现有 Cloudflare IP 段访问，提供 HTTP-01 验证与 HTTPS 跳转；443 继续保留原 Cloudflare 来源限制。DNS 橙云应保持开启。若启用 Cloudflare 挑战规则，应确保 ACME 验证路径可访问。

## 回退

删除 /etc/nginx/sites-enabled/cc-website 链接并 nginx -t 后重载，只下线官网。不要修改 node.tangchen02.top 的站点配置、更新目录或订阅服务。

## 手机检测

入口 `/apps/cc-assistant/check/`，源码 `website/check/`。浏览器只请求 Claude 相关、由 Cloudflare 提供 trace 的公开地址（API、网页、登录、开发平台、官网、Artifacts、短链接、Auth0）；不得改为服务器转发，否则会把服务器出口误报成手机出口。`connect-src` 仅允许这些检测目标。

不自动开始检测；单次并发请求，10 秒超时，不带跨站 Cookie。只有用户主动保存基准时才写浏览器 localStorage，可在页面清除。复制结果含 IP，仅进入用户剪贴板。网页无法读取小火箭配置，也不能代表其他 App 的流量路径；受跨域或网络限制的结果单独显示，提供手动打开目标的入口。

## 使用说明

小火箭导入说明已移至 [小火箭 Claude 专项扩展](shadowrocket-usage.md)。
