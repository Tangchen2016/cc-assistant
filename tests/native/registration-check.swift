import Foundation

@main struct RegistrationChecks {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cc-registration-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        precondition(RegistrationModel.domainValid("owned-example.com"))
        for value in ["http://example.com", "localhost", "127.0.0.1", "private.local", "example.com/path", "a..com"] { precondition(!RegistrationModel.domainValid(value)) }
        for value in ["http://user:password@proxy.example:7890", "http://localhost", "file:///tmp/proxy", "http://127.0.0.1:7890?key=secret"] { do { _ = try RegistrationModel.proxyArgument(value); preconditionFailure("Unsafe proxy accepted") } catch {} }
        let model = RegistrationModel(directory: root)
        model.settings.domain = "owned-example.com"; model.settings.destination = "inbox@owned-example.com"
        model.save()
        let loaded = RegistrationModel(directory: root)
        precondition(loaded.settings.browserID == model.settings.browserID)
        precondition(loaded.settings.domain == "owned-example.com")
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("settings.json").path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let arguments = try loaded.arguments(for: "about:blank")
        precondition(arguments.contains("--proxy-server=http://127.0.0.1:7890"))
        let configuration = try loaded.browserConfiguration()
        precondition(!configuration.executable.path.contains("CCBaga"))
        let temporaryProfile = root.appendingPathComponent("temporary-probe")
        let probeArguments = configuration.arguments(profile: temporaryProfile)
        precondition(probeArguments.contains("--proxy-server=http://127.0.0.1:7890"))
        precondition(probeArguments.contains("--disable-quic") && probeArguments.contains("--disable-extensions"))
        precondition(!probeArguments.contains { $0.contains(loaded.settings.browserID.uuidString) })
        for flag in probeArguments where !flag.hasPrefix("--user-data-dir=") { precondition(arguments.contains(flag)) }
        let body = PureBrowserProbe.traceText("<html><pre>h=api.anthropic.com\nip=203.0.113.1\nloc=US\n</pre></html>")!
        precondition(EgressLocalDiagnostics.parse(body, host: "api.anthropic.com", kind: .browser, milliseconds: 1).isSuccess)
        precondition(!EgressLocalDiagnostics.parse(body, host: "claude.ai", kind: .browser, milliseconds: 1).isSuccess)
        precondition(PureBrowserProbe.traceText("<html>Login required</html>") == nil)
        precondition(arguments.contains { $0.hasPrefix("--user-data-dir=" + root.path + "/chrome-profiles/") })
        precondition(!arguments.contains { $0.contains("owned-example.com") || $0.contains("Google/Chrome") })
        do { _ = try loaded.arguments(for: "https://untrusted.example/"); preconditionFailure("Unknown start page accepted") } catch {}
        let previous = loaded.settings.browserID; loaded.newBrowserEnvironment(); precondition(loaded.settings.browserID != previous)
        print("Registration checks passed: private persistence, stable isolated profile, explicit proxy, URL boundaries, new environment. No browser launched.")
    }
}
