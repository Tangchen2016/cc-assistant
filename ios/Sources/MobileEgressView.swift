import SwiftUI

struct MobileEgressView: View {
    @ObservedObject var model: MobileEgressModel
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 9) {
                    Text("确认你的 Claude 网络出口").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    Text("检测此 iPhone App 的实际请求路径").font(.footnote).foregroundStyle(.secondary)
                }
                Button(action: model.start) {
                    ZStack {
                        Circle().stroke(MobileStyle.accent.opacity(0.12), lineWidth: 1).frame(width: 154, height: 154)
                        Circle().fill(MobileStyle.accent.gradient).frame(width: 126, height: 126)
                        if model.running { Circle().trim(from: 0, to: CGFloat(model.finishedCount) / 4).stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 112, height: 112).rotationEffect(.degrees(-90)) }
                        VStack(spacing: 5) {
                            Image(systemName: model.running ? "network" : "arrow.clockwise").font(.title2)
                            Text(model.running ? "\(model.finishedCount) / 4" : model.checkedAt == nil ? "开始检测" : "重新检测").font(.subheadline.weight(.semibold))
                        }.foregroundStyle(.white)
                    }
                }.disabled(model.running).buttonStyle(.plain).accessibilityLabel(model.running ? "检测中，完成 \(model.finishedCount) 项" : "开始检测")
                if model.checkedAt != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(model.isConsistent ? "已检测出口一致" : model.addresses.count > 1 ? "检测到不同出口" : "仍有结果需要确认", systemImage: model.isConsistent ? "checkmark.shield.fill" : "exclamationmark.circle.fill")
                            .font(.headline).foregroundStyle(model.isConsistent ? .green : .orange)
                        ForEach(model.addresses, id: \.self) { ip in
                            HStack(alignment: .top) {
                                Text(ip).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                                Spacer(minLength: 4)
                                Button(model.marker == ip ? "已标记" : "标记") { model.mark(ip) }.font(.caption)
                            }
                        }
                        if let marker = model.marker { Text(model.addresses.contains(where: { $0 != marker }) ? "本次存在与标记不同的 IP。" : "标记 IP：\(marker)").font(.footnote).foregroundStyle(.secondary) }
                        Text("出口一致仅代表本次读取结果，不代表完整登录或服务可用性。").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.background, in: RoundedRectangle(cornerRadius: 18))
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("标记的 IP").font(.subheadline.weight(.semibold)); Spacer(); if model.marker != nil { Button("取消标记") { model.mark(nil) }.font(.caption) } }
                    Text(model.marker ?? "尚未标记").font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    Text("只保留一个标记，选择新 IP 会替换旧标记。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("设备时区").font(.subheadline.weight(.semibold))
                    Text(TimeZone.autoupdatingCurrent.identifier).font(.footnote)
                    Text("本机当前时区，未读取或修改 Safari 时区。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                DisclosureGroup("检测明细") {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(model.results) { result in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(result.host).font(.footnote.weight(.medium))
                                Text(result.ip ?? result.error ?? (model.running ? "检测中" : "尚未检测")).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                                if let country = result.country { Text("\(country) · \(result.elapsed ?? 0) ms").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
                }.font(.subheadline)
                Text("请先在代理客户端连接所需线路。本页不读取或修改代理规则，不代表 Safari 或其他 App 的出口。").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }.background(MobileStyle.paper).navigationTitle("环境检测").navigationBarTitleDisplayMode(.inline)
    }
}
