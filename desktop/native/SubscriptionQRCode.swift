import SwiftUI
import CoreImage.CIFilterBuiltins

enum LocalQRCode {
    static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

enum SubscriptionMobileImport {
    enum Mode: String, CaseIterable {
        case nodes = "小火箭节点"
        case guide = "规则安装向导"
        case clash = "Clash 订阅"
    }
    static func guide(address: String, name: String, standalone: Bool = false) -> String? {
        guard let url = URLComponents(string: address), url.scheme == "https", url.host == "node.tangchen02.top", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.port == nil || url.port == 443 else { return nil }
        return "https://tangchen02.top/apps/cc-assistant/import/#url=\(SubscriptionCore.encoded(address))&name=\(SubscriptionCore.encoded(name))" + (standalone ? "&mode=shadowrocket" : "")
    }
    static func exportURL(address: String, format: String) -> String? {
        guard guide(address: address, name: "") != nil, ["shadowrocket-nodes", "shadowrocket-module"].contains(format), var url = URLComponents(string: address) else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3 || parts.count == 4, parts[0] == "remote-sub", parts[1].count == 32, parts[2].count == 64, (parts[1] + parts[2]).allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        url.path = "/" + parts.prefix(3).joined(separator: "/") + (format == "shadowrocket-nodes" ? "/claude-nodes.txt" : "/claude.module")
        url.queryItems = [URLQueryItem(name: "format", value: format)]
        return url.string
    }
    static func nodes(address: String, name: String) -> String? {
        guard let url = exportURL(address: address, format: "shadowrocket-nodes") else { return nil }
        let title = String(name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(120)) + " · Claude 节点"
        return "sub://" + Data(url.utf8).base64EncodedString() + "?remark=" + SubscriptionCore.encoded(title)
    }
}

struct SubscriptionQRCode: View {
    let record: SubscriptionRecord
    @Binding var mode: SubscriptionMobileImport.Mode
    let close: () -> Void
    private var address: String? {
        guard let value = record.remote?.subscriptionUrl, let url = URL(string: value), url.scheme == "https", let host = url.host, host != "localhost", host != "127.0.0.1", host != "::1" else { return nil }
        return value
    }
    var body: some View {
        VStack(spacing: 18) {
            HStack { Text("手机扫码订阅").font(.title2); Spacer(); Button("关闭", action: close) }
            Text(record.profile.name).font(.headline)
            if let address {
                Picker("扫码内容", selection: $mode) {
                    ForEach(SubscriptionMobileImport.Mode.allCases.filter { !record.profile.isShadowrocket || $0 != .clash }, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if let payload = payload(address), let qr = LocalQRCode.image(payload) {
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable().scaledToFit().frame(width: 230, height: 230).padding(24).background(.white).accessibilityLabel("远程订阅二维码，包含访问密钥")
                    Text(mode == .nodes ? "用小火箭首页左上角扫一扫，添加 Claude 专用节点。" : mode == .guide ? "用 iPhone 系统相机扫码，在 Safari 中打开规则安装向导。" : "原始增强订阅，适用于 Clash / Mihomo。").font(.system(size: 13))
                    Button(mode == .nodes ? "复制节点订阅地址" : mode == .guide ? "复制规则安装向导链接" : "复制 Clash 订阅地址") {
                        if let copied = mode == .nodes ? SubscriptionMobileImport.exportURL(address: address, format: "shadowrocket-nodes") : payload {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copied, forType: .string)
                        }
                    }
                } else { Text("当前远程服务暂不支持向导，或地址过长。请重新发布到当前远程服务。").foregroundStyle(.orange) }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Claude 专项扩展").font(.system(size: 13, weight: .semibold))
                    Text("1. 用小火箭扫“小火箭节点”添加订阅；再切换“规则安装向导”，用系统相机扫码安装模块。")
                    Text("2. 模块只扩展 Claude 域名，不复制 iKuuu 等源订阅分组。")
                    Text("3. 选回通用或默认配置，不再使用旧的完整增强配置；全局路由保持“配置”。")
                    Text(record.profile.isShadowrocket ? "4. 需要链式代理时，在固定出口节点的“代理通过”中选择已有普通节点；默认是直接连接出口。" : "4. 链式前置默认使用源分组展开后的首个明确节点，可在手机“代理通过”中改选。")
                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                Text("二维码包含订阅访问密钥，请勿公开分享。").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "qrcode").font(.system(size: 64)).foregroundStyle(.secondary).padding()
                Text("请先启用远程订阅").font(.headline)
                Text("手机无法访问这台 Mac 的 127.0.0.1 地址。请在“查看地址”中发布远程订阅，再打开二维码。").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }.padding(26).frame(width: 520).fixedSize(horizontal: false, vertical: true)
            .onAppear { if record.profile.isShadowrocket && mode == .clash { mode = .nodes } }
    }
    private func payload(_ address: String) -> String? {
        switch mode {
        case .nodes: return SubscriptionMobileImport.nodes(address: address, name: record.profile.name)
        case .guide: return SubscriptionMobileImport.guide(address: address, name: record.profile.name, standalone: record.profile.isShadowrocket)
        case .clash: return record.profile.isShadowrocket ? nil : address
        }
    }
}
