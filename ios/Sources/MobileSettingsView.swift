import SwiftUI
import UniformTypeIdentifiers

struct AccountBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct MobileSettingsView: View {
    @ObservedObject var model: AccountPoolModel
    @State private var exporting = false
    @State private var importing = false
    @State private var document = AccountBackupDocument(data: Data())
    @State private var message = ""
    var body: some View {
        List {
            Section {
                Button("导出号池备份", systemImage: "square.and.arrow.up") {
                    do { document = AccountBackupDocument(data: try model.store.backupData()); exporting = true }
                    catch { message = error.localizedDescription }
                }.disabled(model.store.loadError != nil)
                Button("导入号池备份", systemImage: "square.and.arrow.down") { importing = true }.disabled(model.store.loadError != nil)
            } header: { Text("本地资料") } footer: { Text("与 Mac / 网页号池使用相同 JSON 格式。导入会合并新记录；遇到同邮箱或版本冲突时不覆盖已有资料。") }
            if !message.isEmpty { Section { Text(message).font(.footnote) } }
            Section("隐私与登录") {
                Text("号池仅保存在此 App 的私有目录，不会上传或自动同步。请定期保存备份。")
                Text("可在接入时识别 Claude 账号。Session 由你提供，保存在此 App 的私有文件；不使用系统钥匙串，普通号池备份不包含会话。")
            }
            Section("关于") {
                LabeledContent("版本", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                Link("cc助手官网", destination: URL(string: "https://tangchen02.top/apps/cc-assistant/")!)
            }
        }.navigationTitle("设置与备份")
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "cc-accounts") { result in
            switch result { case .success: message = "备份已导出，请妥善保存。"; case .failure(let error): message = "未导出：\(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
                try model.importData(data); message = model.notice
            } catch { message = "未导入：\(error.localizedDescription)" }
        }
    }
}
