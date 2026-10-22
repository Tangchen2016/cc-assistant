# 小火箭 Claude 专项扩展


远程订阅地址增加 `format=shadowrocket-nodes` 下载专用节点（Base64 URI）；`format=shadowrocket-module` 下载仅含 `[Rule]` 的 Claude 模块。默认格式仍为完整 Clash YAML，现有链接不变。两个导出使用相同下载密钥，并按原策略拉取最新源或使用授权的原始源缓存。

模块只接受 Claude 三个根域及其子域的 DOMAIN / DOMAIN-SUFFIX 规则，不复制源订阅分组、FINAL、DNS、MITM 或其他网站规则。节点包只导出被这些规则引用的出口及其前置；组内多个出口取首个已选出口，前置源分组取首个明确节点。输出仅支持实现中明确处理的 SS、VMess、VLESS、Trojan TCP/WS 子集，不支持的插件、已有链和协议会报错，不退回普通节点。

`/apps/cc-assistant/import/` 为手机两步导入向导。App 二维码将远程地址和名称放入 URL fragment，浏览器读取后从地址栏清除，不写本地存储。向导分别提供添加节点、安装规则模块及手动复制备用操作；不能把向导二维码放进小火箭首页当节点扫，应该用手机系统相机在 Safari 打开。

应选回原通用/默认配置并启用模块，不再使用旧的整份增强配置。手机实际代理链、模块解析及切换普通订阅后的出口一致性须在 Shadowrocket 真机验收，服务端和二维码测试不能代替它。
