import Cocoa
import SwiftUI

/// Grouped-form sections for one browser environment; place inside a `Form`.
struct BrowserSettingsPage: View {
    @ObservedObject var model: RegistrationModel
    @State private var folders: [RegistrationModel.ProfileFolder] = []
    private let commonZones = ["America/Los_Angeles", "America/New_York", "Europe/London", "Asia/Tokyo", "Asia/Singapore", "Asia/Shanghai", "UTC"]
    private var unavailable: Bool { model.engine == nil || model.openingBrowser || model.browserRuntime.phase == .stopping }
    private var runtimeColor: Color { model.browserRuntime.phase == .running ? .green : model.browserRuntime.phase == .stopped ? .secondary : .orange }

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Group {
                    if let icon = ChromeBrowserIdentity.badgedImage(executable: model.engine) {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else { Image(systemName: "macwindow").font(.system(size: 22)) }
                }.frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("cc助手浏览器").font(.headline)
                    Text(runtimeDescription).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(text: model.browserRuntime.phase.rawValue, color: runtimeColor)
            }.padding(.vertical, 4)
            HStack {
                Button { model.openBrowser(RegistrationModel.browserCheckPage) } label: {
                    Label(model.openingBrowser ? "启动中…" : "打开并检测", systemImage: "arrow.up.right.square")
                }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(unavailable)
                    .help("打开此环境，并在网页自动检测出口 IP 和浏览器时区")
                Button("打开 Claude") { model.openBrowser("https://claude.ai/") }.disabled(unavailable)
                Spacer()
                Button("关闭浏览器") { model.closeBrowser() }
                    .disabled(model.openingBrowser || model.browserRuntime.pid == nil || model.browserRuntime.phase == .stopping)
                    .help("关闭独立浏览器，保留登录资料")
            }
            if !model.status.isEmpty { Text(model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        Section {
            LabeledContent("代理") {
                HStack {
                    TextField("代理", text: $model.settings.proxy, prompt: Text("http://127.0.0.1:7890"))
                        .labelsHidden().font(.system(.body, design: .monospaced)).frame(maxWidth: 260)
                    if LineEngine.enabled {
                        Button("使用内置代理") { model.settings.proxy = LineEngine.address }
                            .disabled(model.settings.proxy == LineEngine.address)
                    }
                }
            }
            LabeledContent("时区") { zonePicker.frame(maxWidth: 260) }
            exitSummary
        } header: { Text("网络与时区") } footer: {
            HStack {
                Text("更改后重新打开浏览器生效，不影响系统时区。")
                Spacer()
                Button("保存设置") { model.save() }
            }
        }
        Section("资料目录") {
            ForEach(folders) { folder in
                HStack(spacing: 10) {
                    Image(systemName: folder.id == model.settings.browserID ? "checkmark.circle.fill" : "circle").foregroundStyle(folder.id == model.settings.browserID ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.id.uuidString.prefix(8)).font(.system(.body, design: .monospaced))
                        Text([folder.created?.formatted(date: .abbreviated, time: .shortened), ByteCountFormatter.string(fromByteCount: folder.bytes, countStyle: .file), folder.hasLogin ? "有登录资料" : "无登录资料"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if folder.id == model.settings.browserID { Text("当前使用").font(.caption).foregroundStyle(.secondary) }
                    else { Button("切换到此目录") { model.useProfile(folder.id) }.disabled(model.browserRuntime.pid != nil).help("切回此目录，沿用其中的登录资料；需先关闭独立浏览器") }
                }
            }
            LabeledContent("新建资料目录") { Button("新建空白目录") { model.newBrowserEnvironment() }.help("当前目录会保留，可随时切回") }
            Text("资料目录保存登录状态、Cookie 与浏览记录；旧目录不会删除。它不是网站识别的设备指纹。")
                .font(.callout).foregroundStyle(.secondary)
        }.task(id: model.settings.browserID) { let dir = model.directory; folders = await Task.detached { RegistrationModel.profileFolders(in: dir) }.value }
    }

    private var runtimeDescription: String {
        switch model.browserRuntime.phase {
        case .restartRequired: return "设置已改变，关闭后重新打开以应用。"
        case .unverified: return "启动设置尚未确认，请打开检测页核对。"
        default: return model.engineName + " · 独立资料目录"
        }
    }

    private var zonePicker: some View {
        Picker("时区", selection: Binding(get: { model.settings.timeZone ?? "" }, set: { model.settings.timeZone = $0.isEmpty ? nil : $0 })) {
            if let recommendation = model.exitTimeZone {
                Text("推荐 · \(recommendation.identifier)").tag(recommendation.identifier)
                Divider()
            }
            Text("跟随系统（\(TimeZone.autoupdatingCurrent.identifier)）").tag("")
            ForEach(commonZones, id: \.self) { if $0 != model.exitTimeZone?.identifier { Text($0).tag($0) } }
            Divider()
            ForEach(TimeZone.knownTimeZoneIdentifiers.filter { !commonZones.contains($0) && $0 != model.exitTimeZone?.identifier }, id: \.self) { Text($0).tag($0) }
        }.labelsHidden()
    }

    private var exitSummary: some View {
        LabeledContent("出口") {
            HStack(spacing: 8) {
                if let exit = model.exitTimeZone {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(exit.ip).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text("\(exit.location) · \(exit.identifier)").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.checkingExitTimeZone ? "正在检测…" : model.exitTimeZoneMessage.isEmpty ? "未检测" : model.exitTimeZoneMessage)
                        .foregroundStyle(.secondary).lineLimit(2)
                }
                Button { Task { await model.refreshExitTimeZone(force: true) } } label: {
                    if model.checkingExitTimeZone { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }.buttonStyle(.borderless).disabled(model.checkingExitTimeZone)
                    .help("刷新出口 IP 与时区").accessibilityLabel("刷新出口 IP 与时区")
            }
        }
    }
}
