import SwiftUI

enum AccountGuideSection: String, CaseIterable {
    case registration, payment, usage
    var title: String {
        switch self { case .registration: return "注册准备"; case .payment: return "订阅与支付"; case .usage: return "开始使用" }
    }
    var symbol: String {
        switch self { case .registration: return "person.crop.circle.badge.plus"; case .payment: return "creditcard"; case .usage: return "bubble.left.and.bubble.right" }
    }
    static func forRoute(_ route: String) -> Self? {
        ["domain", "email"].contains(route) ? .registration : Self(rawValue: route)
    }
}
@MainActor final class AccountGuideNavigation: ObservableObject {
    private let defaults: UserDefaults
    @Published var section: AccountGuideSection {
        didSet { defaults.set(section.rawValue, forKey: "accountGuideSection") }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        section = defaults.string(forKey: "accountGuideSection").flatMap(AccountGuideSection.init(rawValue:)) ?? .registration
    }
}

struct AccountGuideView: View {
    @ObservedObject var browser: RegistrationModel
    @ObservedObject var navigation: AccountGuideNavigation
    let onNavigate: (String) -> Void
    private let accent = Theme.accent
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "指南", subtitle: "从注册准备到日常使用，在这里找到对应操作。") { EmptyView() }
                Picker("指南分类", selection: $navigation.section) {
                    ForEach(AccountGuideSection.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }.padding(.horizontal, 32).padding(.top, 28)
                .frame(maxWidth: Theme.contentWidth, alignment: .leading).frame(maxWidth: .infinity)
            LifecyclePage(heading: navigation.section.title, subtitle: subtitle, items: actions, compact: true)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var subtitle: String {
        switch navigation.section {
        case .registration: return "准备域名和邮箱，再通过独立浏览器完成官方注册或登录。"
        case .payment: return "沿用账号的独立浏览器环境，在官方账单页面完成订阅与支付。"
        case .usage: return "打开 Claude 开始使用，需要时核对网络出口或调整线路。"
        }
    }
    private var actions: [(String, String, String, () -> Void)] {
        switch navigation.section {
        case .registration: return [
            ("globe", "1. 域名准备", "购买或复用域名，接入 Cloudflare。", { onNavigate("domain") }),
            ("envelope", "2. 域名邮箱配置", "验证收件邮箱，配置 Catch-all，并测试验证码收信。", { onNavigate("email") }),
            ("person.crop.circle.badge.plus", "3. 注册新账号并入库", "在官网完成注册后，核对邮箱并加入号池。", { onNavigate("account-register") }),
            ("person.2.crop.square.stack", "4. 记录已创建的账号", "加入号池，记录状态、订阅类型和到期日。", { onNavigate("accounts") })
        ]
        case .payment: return [
            ("creditcard", "打开官方账单页面", "在当前独立浏览器中打开 Claude 账单，由本人完成支付。", { browser.openBrowser("https://claude.ai/settings/billing") }),
            ("macwindow", "管理独立浏览器", "查看运行状态，统一管理代理和时区。", { onNavigate("browser") })
        ]
        case .usage: return [
            ("bubble.left.and.bubble.right", "打开 Claude", "沿用当前独立环境的登录资料。", { browser.openBrowser("https://claude.ai/") }),
            ("shield.lefthalf.filled", "检查使用环境", "核对 Claude 请求的出口 IP、时区及变化。", { onNavigate("environment") }),
            ("arrow.triangle.branch", "管理 Claude 线路", "管理订阅、独立出口和静态 IP 节点。", { onNavigate("enhancement") })
        ]
        }
    }
}
