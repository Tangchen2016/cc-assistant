import Cocoa
import Sparkle
import SwiftUI

@MainActor final class AppUpdates: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    @Published private(set) var version = ""
    @Published private(set) var status = ""
    @Published private(set) var failure = ""
    @Published private(set) var running = false
    @Published private(set) var progress: Double?
    @Published private(set) var canCancel = false
    @Published private(set) var checking = false
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var checkMessage = ""
    static let checkInterval: TimeInterval = 60 * 60
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var installRequested = false
    private var manualCheck = false
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private let prepareInstallation: () -> Bool
    private lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
    init(prepareInstallation: @escaping () -> Bool) { self.prepareInstallation = prepareInstallation; super.init() }

    func start() {
        do {
            try updater.start()
            automaticallyChecks = updater.automaticallyChecksForUpdates
            lastCheckedAt = updater.lastUpdateCheckDate
            updater.automaticallyDownloadsUpdates = false
            updater.updateCheckInterval = Self.checkInterval
            if automaticallyChecks { checking = true; updater.checkForUpdatesInBackground() }
        } catch { failure = "更新检测未启动，请使用菜单重试。"; checkMessage = failure }
    }
    @objc func checkManually() {
        beginCheck(showAlert: true)
    }
    func checkNow() { beginCheck(showAlert: false) }
    func setAutomaticChecks(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecks = updater.automaticallyChecksForUpdates
    }
    private func beginCheck(showAlert: Bool) {
        guard !running else { return }
        if pendingChoice != nil { checkMessage = "已发现 v\(version)，可以点击“立即更新”。"; return }
        guard updater.canCheckForUpdates else { return }
        manualCheck = showAlert; failure = ""; checking = true; checkMessage = "正在检查更新…"; updater.checkForUpdates()
    }
    func install() {
        guard !running else { return }
        guard prepareInstallation() else { failure = "请等待当前操作完成或保存草稿后再更新。"; return }
        failure = ""; installRequested = true
        if let reply = pendingChoice {
            pendingChoice = nil; running = true; status = "准备下载…"; reply(.install)
        } else if updater.canCheckForUpdates { updater.checkForUpdates() }
    }
    func cancel() { let action = cancellation; cancellation = nil; canCancel = false; installRequested = false; action?() }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)) }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { self.cancellation = cancellation; if installRequested { running = true; canCancel = true; status = "检查更新…" } }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !appcastItem.isInformationOnlyUpdate else { failure = "该版本需手动安装，请访问官网下载。"; reply(.dismiss); return }
        version = appcastItem.displayVersionString; failure = ""; cancellation = nil; canCancel = false; checking = false; lastCheckedAt = Date(); checkMessage = "发现新版本 v\(version)"
        if installRequested { running = true; status = "准备下载…"; reply(.install) }
        else { pendingChoice = reply; running = false; status = "" }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        version = ""; status = ""; running = false; checking = false; lastCheckedAt = Date(); checkMessage = "未发现可安装的新版本。"
        if manualCheck { let alert = NSAlert(); alert.messageText = checkMessage; alert.addButton(withTitle: "好"); alert.runModal() }
        acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        failure = "更新失败，请检查网络或磁盘空间后重试。"; running = false; checking = false; checkMessage = failure
        if manualCheck && version.isEmpty { let alert = NSAlert(); alert.messageText = "无法检查更新"; alert.informativeText = failure; alert.addButton(withTitle: "好"); alert.runModal() }
        acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation; canCancel = true; running = true; status = "正在下载…"; expected = 0; received = 0; progress = nil
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expected = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received = received.addingReportingOverflow(length).partialValue
        if expected > 0 { progress = min(1, Double(received) / Double(expected)); status = "正在下载 \(Int((progress ?? 0) * 100))%" }
    }
    func showDownloadDidStartExtractingUpdate() { cancellation = nil; canCancel = false; progress = nil; status = "正在校验并解压…" }
    func showExtractionReceivedProgress(_ progress: Double) { self.progress = progress }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard installRequested, prepareInstallation() else { failure = "更新已下载，请先完成当前操作再重试。"; reply(.dismiss); return }
        running = true; progress = nil; status = "正在安装并重启…"; reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { status = "正在安装并重启…"; running = true }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { pendingChoice = nil; cancellation = nil; canCancel = false; running = false; checking = false; progress = nil; status = ""; installRequested = false; manualCheck = false }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { if !item.isInformationOnlyUpdate { version = item.displayVersionString }; lastCheckedAt = Date(); checking = false; checkMessage = "发现新版本 v\(version)" }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { version = ""; lastCheckedAt = Date(); checking = false; checkMessage = "未发现可安装的新版本。" }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        checking = false
        if let error {
            let detail = error as NSError
            if detail.domain != SUSparkleErrorDomain || detail.code != Int(SUError.noUpdateError.rawValue) { checkMessage = "暂时无法检查更新，请稍后重试。" }
        }
    }
}

struct UpdateSidebarView: View {
    @ObservedObject var updates: AppUpdates
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !updates.version.isEmpty {
                Button(action: updates.install) {
                    Label(updates.running ? updates.status : "更新到 v\(updates.version)", systemImage: "arrow.down.circle")
                        .font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(Theme.accent).disabled(updates.running)
                    .help("下载签名更新，安装后自动重启；配置会保留。")
                if updates.running { ProgressView(value: updates.progress).controlSize(.small) }
                if updates.canCancel { Button("取消下载", action: updates.cancel).buttonStyle(.borderless).font(.system(size: 10)) }
                if !updates.failure.isEmpty { Text(updates.failure).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }.frame(width: 180, alignment: .leading)
    }
}
