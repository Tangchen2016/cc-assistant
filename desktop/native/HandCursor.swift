import AppKit

/// Pointing-hand cursor over anything clickable, app-wide. Uses each window's accessibility
/// hit-test, so every SwiftUI/AppKit button, menu, checkbox and toggle is covered without
/// touching call sites; text fields keep their I-beam.
@MainActor enum HandCursor {
    private static var monitor: Any?
    private static var showing = false
    private static var lastCheck = Date.distantPast
    private static let clickable: Set<NSAccessibility.Role> = [.button, .popUpButton, .menuButton, .checkBox, .radioButton, .link, .disclosureTriangle, .incrementor]

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited]) { event in
            update(event); return event
        }
    }
    /// Windows only deliver mouse-moved events when asked to.
    static func track(_ window: NSWindow?) { window?.acceptsMouseMovedEvents = true }

    private static func update(_ event: NSEvent) {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 0.04 else { if showing { NSCursor.pointingHand.set() }; return }  // ~25 checks/s
        lastCheck = now
        guard event.type == .mouseMoved, let window = event.window else { reset(); return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if isClickable(window.accessibilityHitTest(point)) { NSCursor.pointingHand.set(); showing = true } else { reset() }
    }
    private static func reset() { if showing { NSCursor.arrow.set(); showing = false } }

    private static func isClickable(_ hit: Any?) -> Bool {
        var element = hit as? NSAccessibilityProtocol
        for _ in 0..<3 {  // SwiftUI often hit-tests a label inside the button
            guard let current = element else { return false }
            let role = current.accessibilityRole()
            if let role, clickable.contains(role) { return current.isAccessibilityEnabled() }
            if role == .textField || role == .textArea { return false }
            element = current.accessibilityParent() as? NSAccessibilityProtocol
        }
        return false
    }
}
