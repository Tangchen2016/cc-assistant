import SwiftUI
import AppKit

struct MobileCheckEntrySheet: View {
    @ObservedObject var model: EgressCheckModel
    private let address = "https://tangchen02.top/apps/cc-assistant/check/"
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Label("手机环境检测", systemImage: "iphone")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("关闭") { model.showMobileCheck = false }
            }
            Text("用手机相机或浏览器扫码，免安装打开检测页。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if let qr = LocalQRCode.image(address) {
                Image(decorative: qr, scale: 1)
                    .interpolation(.none).resizable().scaledToFit()
                    .frame(width: 250, height: 250).padding(24).background(.white)
                    .accessibilityLabel("手机环境检测网页二维码")
            } else {
                Text("二维码生成失败，请复制链接在手机打开。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text("先在手机开启小火箭，再点击网页里的“开始检测”。")
                .font(.system(size: 13, weight: .medium))
            Text("查看手机浏览器的出口 IP、地区和请求耗时，核对 Claude 域名的实际线路。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(address).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    model.mobileLinkCopied = NSPasteboard.general.setString(address, forType: .string)
                } label: { Label(model.mobileLinkCopied ? "已复制链接" : "复制链接", systemImage: model.mobileLinkCopied ? "checkmark" : "doc.on.doc") }
                Button("在浏览器打开") {
                    if let url = URL(string: address) { NSWorkspace.shared.open(url) }
                }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }.controlSize(.large)
        }.padding(26).frame(width: 470)
    }
}
