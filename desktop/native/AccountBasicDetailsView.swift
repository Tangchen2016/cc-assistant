import SwiftUI

struct AccountBasicDetailsView: View {
    @ObservedObject var model: AccountPoolModel
    let accountID: UUID
    @Environment(\.dismiss) private var dismiss
    private var record: AccountPoolRecord? { model.records.first { $0.id == accountID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("账号详情").font(.system(size: 22, weight: .semibold))
            if let row = record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        section("基本信息") {
                            item("邮箱", row.email)
                            item("账号 ID", row.identity?.accountID)
                            item("姓名", row.identity?.name)
                            item("显示昵称", row.identity?.details?.displayName)
                            item("注册时间", date(row.identity?.remoteCreatedAt))
                            item("入库时间", date(row.recordedAt) ?? "未记录（旧版数据）")
                            item("手动记录日期", date(row.createdAt))
                            item("最近成功读取", date(row.identity?.checkedAt))
                            item("官网资料更新时间", date(row.identity?.details?.remoteUpdatedAt))
                            item("验证状态", flag(row.identity?.details?.verified, yes: "已验证", no: "未验证"))
                            item("完成验证时间", date(row.identity?.details?.verificationCompletedAt))
                            item("注册引导", flag(row.identity?.details?.onboardingComplete, yes: "已完成", no: "未完成"))
                        }
                        section("套餐与检测") {
                            item("记录套餐", row.subscription.isEmpty ? nil : row.subscription)
                            item("接口识别套餐", row.identity?.plan.map { $0 + (row.identity?.planIsInferred == true ? "（推断）" : "") })
                            item("手动到期日", date(row.expiresAt))
                            item("本次读取状态", model.connectionText(row))
                            Text("验证状态表示官网的 is_verified 字段，不等于付费状态或账号可用性保证。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if let organizations = row.identity?.details?.organizations, !organizations.isEmpty {
                            ForEach(Array(organizations.enumerated()), id: \.offset) { index, org in
                                section("组织信息 \(organizations.count > 1 ? String(index + 1) : "")") {
                                    item("组织名称", org.name)
                                    item("组织 ID", org.id)
                                    item("角色", org.role)
                                    item("席位档位", org.seatTier)
                                    item("套餐标识", org.analyticsPlan)
                                    item("套餐展示名称", org.planDisplayName)
                                    item("套餐标签", org.planDisplayLabel)
                                    item("额度档位", org.rateLimitTier)
                                    item("计费类型", org.billingType)
                                    item("账单提示", org.billingIssue)
                                    item("访问限制提示", org.accessBlock)
                                    item("订阅暂停提示", org.subscriptionPause)
                                    item("API 禁用提示", org.apiDisabledReason)
                                }
                            }
                        } else {
                            Text("尚无组织详情，刷新账号信息后查看。").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }.padding(.trailing, 6)
                }
                HStack {
                    Text("缺失字段显示未获取；日期按本机时区展示。").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.refreshing.contains(row.id) ? "正在刷新…" : "刷新信息") { model.refresh(row) }
                        .disabled(model.refreshing.contains(row.id) || !model.connections.exists(row.id) || row.deletedAt != nil)
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else { Text("账号记录不存在。"); Button("关闭") { dismiss() } }
        }.padding(24).frame(width: 640, height: 650)
    }
    private func date(_ value: Date?) -> String? { value?.formatted(date: .numeric, time: .standard) }
    private func flag(_ value: Bool?, yes: String, no: String) -> String? { value.map { $0 ? yes : no } }
    private func item(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value ?? "未获取").frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.font(.system(size: 12))
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Divider()
            content()
        }.padding(16).background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
