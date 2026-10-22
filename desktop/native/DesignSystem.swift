import AppKit
import SwiftUI

/// Shared look: neutral system surfaces, brand color only for primary actions and status.
enum Theme {
    /// Brand terracotta; brighter in dark mode so it keeps contrast on dark surfaces.
    static let nsAccent = NSColor(name: "ccAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 224 / 255, green: 122 / 255, blue: 95 / 255, alpha: 1)
            : NSColor(srgbRed: 171 / 255, green: 66 / 255, blue: 41 / 255, alpha: 1)
    }
    static let accent = Color(nsColor: nsAccent)
    static let contentWidth: CGFloat = 960
}

/// Scrolling page: title and actions go to the window toolbar, the subtitle opens the content.
struct Page<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: title, subtitle: subtitle, actions: actions)
                content()
            }.padding(.horizontal, 28).padding(.vertical, 24)
                .frame(maxWidth: Theme.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
extension Page where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, actions: { EmptyView() }, content: content)
    }
}

/// Publishes the page title and actions to the window toolbar (HIG: titles and the
/// single primary action live in the toolbar); only the subtitle stays in content.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        Group {
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            else { Color.clear.frame(height: 0) }
        }
        .navigationTitle(title)
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { actions() } }
    }
}

struct CardStyle: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}
extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(CardStyle(padding: padding)) }
}

/// Small heading inside a card.
struct CardTitle: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Dot + text, for running / stopped / warning states.
struct StatusBadge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }.padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: Capsule())
    }
}
