import Foundation
import ServiceManagement

final class LoginItems {
    private let defaults = UserDefaults.standard
    private var lastError: String?

    func configureDefault() {
        if defaults.object(forKey: "loginItemDesired") == nil { defaults.set(true, forKey: "loginItemDesired") }
        // Retry a first registration that failed before installation, while respecting later system/user disabling.
        if defaults.bool(forKey: "loginItemDesired"), !defaults.bool(forKey: "loginItemRegistered"), SMAppService.mainApp.status != .enabled { setEnabled(true) }
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else if service.status != .notRegistered { try service.unregister() }
            defaults.set(enabled, forKey: "loginItemDesired")
            if enabled && (service.status == .enabled || service.status == .requiresApproval) { defaults.set(true, forKey: "loginItemRegistered") }
        } catch {
            lastError = enabled ? "macOS 尚未允许登录时启动，请在系统登录项中确认。" : "无法关闭登录时启动，请在系统登录项中关闭。"
        }
    }

    func state(action: String) -> [String: Any] {
        let status = SMAppService.mainApp.status
        let approval = status == .requiresApproval
        return ["action": action, "ok": lastError == nil, "enabled": status == .enabled,
                "needsApproval": approval, "error": lastError ?? (approval ? "需要在 macOS 登录项中允许 cc助手。" : "")]
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
