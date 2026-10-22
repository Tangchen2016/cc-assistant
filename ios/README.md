# cc助手 iOS 原生版

SwiftUI，最低 iOS 17。当前为 0.2.0 / build 2，使用原生界面与 URLSession，未嵌入网页作为主界面。

功能按“网络与环境 / 账号管理 / 应用设置”分类。提供原生出口检测、单一 IP 标记、设备时区、号池录入编辑筛选与回收站，以及 JSON 备份导入导出。号池复用 Mac 存储和模型；Mac、网页、iPhone 各自本地保存，支持官网注册后接入与 Session 识别，未接自动同步。

## 工程与构建

打开 `CCAssistantIOS.xcodeproj`。`project.yml` 为 XcodeGen 工程源；修改后可在仓库根目录执行：

```sh
xcodegen generate --spec ios/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios/CCAssistantIOS.xcodeproj -scheme CCAssistantIOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath work/ios-build CODE_SIGNING_ALLOWED=NO build
```

图标沿用仓库原有品牌。先运行 Mac 构建生成图标，再执行 `swift ios/make-assets.swift "$PWD"` 可生成无透明通道的 iOS 图标。

## 验证

原生 XCTest 位于 `Tests/MobileTests.swift`。使用具备匹配模拟器组件的 Xcode 选择 iPhone 模拟器运行测试。相同的检测解析、标记、备份逻辑也可用仓库 Swift Package 在 Mac 运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --build-system native --scratch-path work/native-tests --filter 'MobileTests|AccountPoolTests'
```

当前机器 Xcode 27.1 要求 CoreSimulator 1174.9.2，但系统现有组件为 1171.7。通用模拟器构建和测试构建通过，也可使用系统现有模拟器工具安装并启动 App；Xcode 图形设备窗口及 Xcode 管理的模拟器测试尚未验收。完整组件初始化需要管理员操作，未更改系统组件或全局开发工具选择。

如需继续完整模拟器点击与 Xcode 测试，请由本机管理员在终端执行官方组件初始化（需要本机认证，不要在聊天中提供密码）：

```sh
sudo env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -runFirstLaunch
```

## 真机与分发

当前未配置开发团队、未生成可安装到真机的签名包，也未发布 TestFlight。模拟器构建不能作为 IPA 安装到 iPhone。

真机本地安装需在 Xcode 的 Signing & Capabilities 中选择自己的团队，连接并授权 iPhone 后运行。TestFlight 分发还需配置相应开发团队与 App Store Connect 应用；不要向聊天发送 Apple ID 密码、证书私钥或验证码。

## 数据与检测边界

号池保存在 App 沙盒 Application Support 下的 `Subscription Studio/accounts.json`。导入不覆盖冲突版本；删除进入可恢复回收站。台账不会上传。用户提供的 Session 只发往 claude.ai 读取账号身份；关联文件独立保存且不使用系统钥匙串，不包含在普通备份中。

检测向四个固定 Claude 域名的公开 trace 接口发送不带 Cookie 的请求，仅代表这个 App 的出口，不代表 Safari、其他 App 或登录后服务可用性。时区为设备当前时区，未改系统设置。

注册 / Session 接入流程与保存方式见仓库 docs/account-onboarding.md。Safari 会话不能跨 App 直接读取，iPhone 需要由用户提供 Session。
