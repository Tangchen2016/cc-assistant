import XCTest
@testable import SubscriptionStudio

final class AccountPoolTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cc-account-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("accounts.json")
    }
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor func testSaveEditReloadAndPrivatePermissions() throws {
        let file = try temporaryFile(), store = AccountPoolStore(fileURL: file)
        var draft = AccountPoolDraft(email: "  Example@EXAMPLE.COM \n", label: "  我的账号  ", status: .inUse, subscription: "Pro", expiresAt: date.addingTimeInterval(86400), createdAt: date, notes: "手动记录")
        let row = try store.save(draft, now: date)
        XCTAssertEqual(row.email, "example@example.com")
        XCTAssertEqual(row.label, "我的账号")
        draft.label = "修改后的名称"; draft.subscription = "Max"; draft.expiresAt = nil
        let edited = try store.save(draft, id: row.id, now: date.addingTimeInterval(60))
        XCTAssertEqual(edited.id, row.id)
        XCTAssertEqual(edited.createdAt, date)
        XCTAssertNil(edited.expiresAt)
        let loaded = AccountPoolStore(fileURL: file)
        XCTAssertNil(loaded.loadError)
        XCTAssertEqual(loaded.records, [edited])
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    @MainActor func testInvalidAndDuplicateEditsDoNotMutateSavedData() throws {
        let file = try temporaryFile(), store = AccountPoolStore(fileURL: file)
        let first = try store.save(.init(email: "first@example.com", createdAt: date), now: date)
        let second = try store.save(.init(email: "second@example.com", createdAt: date), now: date)
        let original = try Data(contentsOf: file)
        for email in [" FIRST@example.com ", "invalid", "bad\n@example.com"] {
            XCTAssertThrowsError(try store.save(.init(email: email, createdAt: date), id: second.id, now: date))
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(store.records, [first, second])
        }
        XCTAssertThrowsError(try store.save(.init(email: "other@example.com", createdAt: date), id: UUID(), now: date))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor func testRecoverableDeletionAndConflictingRestore() throws {
        let file = try temporaryFile(), store = AccountPoolStore(fileURL: file)
        let first = try store.save(.init(email: "same@example.com", createdAt: date), now: date)
        try store.delete(first.id, now: date)
        XCTAssertNotNil(AccountPoolStore(fileURL: file).records.first?.deletedAt)
        let replacement = try store.save(.init(email: "same@example.com", label: "替代记录", createdAt: date), now: date)
        let data = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.restore(first.id, now: date))
        XCTAssertEqual(try Data(contentsOf: file), data)
        try store.delete(replacement.id, now: date)
        try store.restore(first.id, now: date)
        let loaded = AccountPoolStore(fileURL: file)
        XCTAssertEqual(loaded.records.filter { $0.deletedAt == nil }.map(\.id), [first.id])
        XCTAssertEqual(loaded.records.count, 2)
    }

    @MainActor func testDamagedFutureAndOversizedFilesArePreserved() throws {
        for data in [Data("not json".utf8), Data(#"{"version":2,"accounts":[]}"#.utf8), Data(repeating: 32, count: 4 * 1024 * 1024 + 1)] {
            let file = try temporaryFile()
            try data.write(to: file)
            let store = AccountPoolStore(fileURL: file)
            XCTAssertNotNil(store.loadError)
            XCTAssertThrowsError(try store.save(.init(email: "new@example.com", createdAt: date), now: date))
            XCTAssertEqual(try Data(contentsOf: file), data)
            XCTAssertTrue(store.records.isEmpty)
        }
    }

    @MainActor func testWriteFailureDoesNotChangeMemoryOrExistingFile() throws {
        let parent = try temporaryFile()
        let original = Data("parent is a file".utf8)
        try original.write(to: parent)
        let store = AccountPoolStore(fileURL: parent.appendingPathComponent("accounts.json"))
        XCTAssertThrowsError(try store.save(.init(email: "new@example.com", createdAt: date), now: date))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: parent), original)
    }

    @MainActor func testModelValidationSearchFiltersAndEditorCancel() throws {
        let store = AccountPoolStore(fileURL: try temporaryFile())
        try store.save(.init(email: "a@example.com", label: "Primary", status: .inUse, subscription: "Pro", createdAt: date), now: date)
        try store.save(.init(email: "b@example.com", status: .available, subscription: "Max", createdAt: date.addingTimeInterval(1)), now: date)
        let model = AccountPoolModel(store: store)
        model.create(); XCTAssertFalse(model.hasUnsavedChanges)
        model.draft.email = "invalid"; XCTAssertTrue(model.hasUnsavedChanges)
        model.save(); XCTAssertTrue(model.showEditor); XCTAssertFalse(model.editorError.isEmpty)
        model.cancel(); XCTAssertFalse(model.hasUnsavedChanges); XCTAssertEqual(model.records.count, 2)
        model.query = " primary "; XCTAssertEqual(model.visibleRecords.map(\.email), ["a@example.com"])
        model.filter = .available; XCTAssertTrue(model.visibleRecords.isEmpty)
        model.query = "MAX"; XCTAssertEqual(model.visibleRecords.map(\.email), ["b@example.com"])
        let row = try XCTUnwrap(model.visibleRecords.first)
        model.edit(row); model.draft.label = "Changed"; model.save()
        XCTAssertFalse(model.showEditor); XCTAssertEqual(model.records.first { $0.id == row.id }?.label, "Changed")
        model.delete(row); XCTAssertTrue(model.visibleRecords.isEmpty); XCTAssertEqual(model.deletedCount, 1)
        model.showDeleted = true; XCTAssertEqual(model.visibleRecords.count, 1)
        model.restore(row); XCTAssertTrue(model.visibleRecords.isEmpty); XCTAssertEqual(model.deletedCount, 0)
    }

    @MainActor func testBackupMergeRejectsChangedVersionsWithoutOverwriting() throws {
        let file = try temporaryFile(), store = AccountPoolStore(fileURL: file)
        let row = try store.save(.init(email: "one@example.com", createdAt: date), now: date)
        let backup = try store.backupData()
        XCTAssertEqual(try store.importData(backup), 0)
        var changed = row.draft; changed.label = "修改"
        try store.save(changed, id: row.id, now: date)
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.importData(backup))
        XCTAssertEqual(try Data(contentsOf: file), before)
        let other = AccountPoolStore(fileURL: try temporaryFile())
        try other.save(.init(email: "two@example.com", createdAt: date), now: date)
        XCTAssertEqual(try store.importData(other.backupData()), 1)
        XCTAssertEqual(AccountPoolStore(fileURL: file).records.count, 2)
        XCTAssertThrowsError(try store.importData(Data(#"{"version":2,"accounts":[]}"#.utf8)))
    }

    @MainActor func testExpiryUsesLocalCalendarDaysAcrossDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 50)))
        let tomorrow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 6, hour: 23)))
        XCTAssertEqual(AccountPoolModel.daysUntilExpiry(tomorrow, now: now, calendar: calendar), 1)
        XCTAssertEqual(AccountPoolModel.daysUntilExpiry(now.addingTimeInterval(-60), now: now, calendar: calendar), 0)
        XCTAssertEqual(AccountPoolModel.daysUntilExpiry(yesterday, now: now, calendar: calendar), -1)
    }
}
