import Cocoa
import SwiftUI
import WebKit

private let workspaceAccent = NSColor(srgbRed: 8 / 255, green: 123 / 255, blue: 120 / 255, alpha: 1)

private final class WorkspaceNavigationButton: NSButton {
    var selected = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let color = selected ? workspaceAccent : NSColor.secondaryLabelColor
        if selected || isHighlighted {
            (selected ? workspaceAccent.withAlphaComponent(0.11) : NSColor.labelColor.withAlphaComponent(0.04)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))?
            .draw(in: NSRect(x: 13, y: (bounds.height - 17) / 2, width: 17, height: 17))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium), .foregroundColor: selected ? workspaceAccent : NSColor.labelColor]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 41, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

@MainActor final class WorkspaceView: NSView {
    private let webView: WKWebView
    private let content = NSView()
    private let enhancement = WorkspaceNavigationButton()
    private let detection = WorkspaceNavigationButton()
    private let egressModel = EgressCheckModel()
    private var egressView: NSHostingView<EgressDetectionView>?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar; sidebar.blendingMode = .withinWindow; sidebar.state = .active
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        let brand = NSStackView()
        brand.orientation = .horizontal; brand.alignment = .centerY; brand.spacing = 10
        let badge = NSView()
        badge.wantsLayer = true; badge.layer?.cornerRadius = 7; badge.layer?.backgroundColor = workspaceAccent.cgColor
        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold, scale: .medium))
        mark.contentTintColor = .white
        badge.addSubview(mark); mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: 28), badge.heightAnchor.constraint(equalToConstant: 28), mark.centerXAnchor.constraint(equalTo: badge.centerXAnchor), mark.centerYAnchor.constraint(equalTo: badge.centerYAnchor), mark.widthAnchor.constraint(equalToConstant: 17), mark.heightAnchor.constraint(equalToConstant: 17)])
        let title = NSTextField(labelWithString: "cc助手")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        brand.addArrangedSubview(badge); brand.addArrangedSubview(title)
        stack.addArrangedSubview(brand)
        let spacer = NSView(); spacer.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(spacer)
        let section = NSTextField(labelWithString: "工具")
        section.font = .systemFont(ofSize: 11, weight: .medium); section.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(section)
        configure(enhancement, title: "clash增强", symbol: "arrow.triangle.branch", action: #selector(showEnhancement))
        configure(detection, title: "节点检测", symbol: "network", action: #selector(showDetection))
        stack.addArrangedSubview(enhancement); stack.addArrangedSubview(detection)
        let footer = NSStackView()
        footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 5
        let local = NSTextField(labelWithString: "本机运行")
        local.font = .systemFont(ofSize: 11); local.textColor = .secondaryLabelColor
        let version = NSTextField(labelWithString: "v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"))
        version.font = .systemFont(ofSize: 10); version.textColor = .tertiaryLabelColor
        footer.addArrangedSubview(local); footer.addArrangedSubview(version)
        addSubview(sidebar); addSubview(content); sidebar.addSubview(stack); sidebar.addSubview(footer)
        for view in [sidebar, content, stack, footer] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor), sidebar.topAnchor.constraint(equalTo: topAnchor), sidebar.bottomAnchor.constraint(equalTo: bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 190),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 19), footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor), content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        mount(webView)
        if UserDefaults.standard.string(forKey: "selectedMenu") == "detection" { showDetection() } else { showEnhancement() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ button: WorkspaceNavigationButton, title: String, symbol: String, action: Selector) {
        button.title = title; button.target = self; button.action = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.setAccessibilityLabel(title)
        button.bezelStyle = .regularSquare; button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 158).isActive = true
        button.heightAnchor.constraint(equalToConstant: 39).isActive = true
    }

    private func mount(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor), view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }

    private func selection(_ active: WorkspaceNavigationButton, other: WorkspaceNavigationButton) {
        active.selected = true; other.selected = false
    }
    @objc private func showEnhancement() {
        webView.isHidden = false; egressView?.isHidden = true
        selection(enhancement, other: detection); UserDefaults.standard.set("enhancement", forKey: "selectedMenu")
    }
    @objc private func showDetection() {
        if egressView == nil {
            let hosted = NSHostingView(rootView: EgressDetectionView(model: egressModel))
            egressView = hosted; mount(hosted)
        }
        webView.isHidden = true; egressView?.isHidden = false
        selection(detection, other: enhancement); UserDefaults.standard.set("detection", forKey: "selectedMenu")
    }
}
