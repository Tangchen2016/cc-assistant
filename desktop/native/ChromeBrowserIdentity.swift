import AppKit
import Security
import CryptoKit

// Finder custom icons live outside Contents; Chrome's signed files stay intact.
enum ChromeBrowserIdentity {
    struct Signature: Codable, Equatable {
        let identifier: String
        let team: String?
        let cdHash: Data
    }
    private struct Stamp: Codable, Equatable {
        let sourcePath: String
        let signature: Signature
        let iconHash: Data
    }
    private static let lock = NSLock()
    static func bundle(profile: URL) -> URL {
        profile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("browser-runtime/cc助手浏览器.app", isDirectory: true)
    }
    static func executable(profile: URL, source: URL) -> URL {
        bundle(profile: profile).appendingPathComponent("Contents/MacOS/\(source.lastPathComponent)")
    }
    static func signature(bundle: URL) throws -> Signature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw SubscriptionFailure("Chrome 签名校验失败，未启动独立副本。") }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let value = information as? [String: Any], let identifier = value[kSecCodeInfoIdentifier as String] as? String,
              let hash = value[kSecCodeInfoUnique as String] as? Data else { throw SubscriptionFailure("无法读取 Chrome 签名身份。") }
        return .init(identifier: identifier, team: value[kSecCodeInfoTeamIdentifier as String] as? String, cdHash: hash)
    }
    /// cc logo with the user's own installed browser icon as a corner badge, so the copy
    /// reads as "cc's Chrome" in the Dock. The badge is read at runtime, never bundled.
    static func badged(_ base: Data, browser: URL) -> Data {
        guard let cc = NSImage(data: base),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return base }
        let badge = NSWorkspace.shared.icon(forFile: browser.path)
        let side: CGFloat = 1024, size = side * 0.5
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        cc.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        let shadow = NSShadow()
        shadow.shadowBlurRadius = side * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -side * 0.01)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
        badge.draw(in: NSRect(x: side - size - side * 0.01, y: side * 0.01, width: size, height: size))
        context.flushGraphics()
        return bitmap.representation(using: .png, properties: [:]) ?? base
    }
    /// Same composite for display inside cc助手.
    @MainActor private static var badgedCache: [String: NSImage] = [:]
    @MainActor static func badgedImage(executable: URL?) -> NSImage? {
        let key = executable?.path ?? ""
        if let cached = badgedCache[key] { return cached }
        guard let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let data = try? Data(contentsOf: icon) else { return nil }
        let app = executable.map { $0.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
        let image = NSImage(data: app.map { badged(data, browser: $0) } ?? data)
        badgedCache[key] = image
        return image
    }
    static func prepare(source: URL, profile: URL, icon: URL) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let original = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard original.pathExtension == "app" else { return source }
        let iconData = badged(try Data(contentsOf: icon), browser: original)
        let sourceSignature = try signature(bundle: original)
        let stamp = Stamp(sourcePath: original.path, signature: sourceSignature, iconHash: Data(SHA256.hash(data: iconData)))
        let target = bundle(profile: profile), destination = executable(profile: profile, source: source)
        let stampFile = target.deletingLastPathComponent().appendingPathComponent("finder-icon.json")
        if let data = try? Data(contentsOf: stampFile), data.count < 4096,
           let existing = try? JSONDecoder().decode(Stamp.self, from: data), existing == stamp,
           FileManager.default.isExecutableFile(atPath: destination.path), try signature(bundle: target) == sourceSignature {
            // Matching stamp means this verified copy already received the custom icon.
            // Reapplying Finder metadata on every launch can fail while Chrome is running.
            return destination
        }
        let profiles = profile.deletingLastPathComponent()
        for item in (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? [] {
            if BrowserProcessIdentity.read(profile: item, allowedExecutables: [destination]) != nil {
                guard try signature(bundle: target) == sourceSignature else {
                    throw SubscriptionFailure("Chrome 已更新，请先关闭 cc助手的独立浏览器，再重新打开以更新副本。")
                }
                return destination
            }
        }
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent("prepare-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: staging) }
        var copied = EgressLocalDiagnostics.run("/bin/cp", ["-cR", original.path, staging.path], timeout: 90)
        if copied.code != 0 {
            try? FileManager.default.removeItem(at: staging)
            copied = EgressLocalDiagnostics.run("/bin/cp", ["-R", original.path, staging.path], timeout: 180)
        }
        guard copied.code == 0, let image = NSImage(data: iconData), NSWorkspace.shared.setIcon(image, forFile: staging.path, options: []) else {
            throw SubscriptionFailure("独立浏览器图标准备失败，请检查空间和目录权限。")
        }
        guard try signature(bundle: staging) == sourceSignature,
              EgressLocalDiagnostics.run("/usr/bin/codesign", ["--verify", "--deep", staging.path], timeout: 45).code == 0 else {
            throw SubscriptionFailure("独立副本与原 Chrome 签名身份不一致，未启用副本。")
        }
        var previous: URL?
        if FileManager.default.fileExists(atPath: target.path) {
            let retired = parent.appendingPathComponent("previous-\(UUID().uuidString).app")
            try FileManager.default.moveItem(at: target, to: retired); previous = retired
        }
        do { try FileManager.default.moveItem(at: staging, to: target) }
        catch {
            if let previous { try? FileManager.default.moveItem(at: previous, to: target) }
            throw error
        }
        if let previous { try? FileManager.default.trashItem(at: previous, resultingItemURL: nil) }
        try SubscriptionStorage.privateWrite(JSONEncoder().encode(stamp), to: stampFile)
        return destination
    }
}
