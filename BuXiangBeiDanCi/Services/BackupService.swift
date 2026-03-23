import AppKit
import Foundation
import GRDB
import UniformTypeIdentifiers

struct DatabasePaths: Sendable, Equatable {
    let databaseDirectoryURL: URL
    let databaseFileURL: URL
    let stagingDirectoryURL: URL
    let internalBackupsDirectoryURL: URL
    let pendingRestoreManifestURL: URL
    let restoreResultURL: URL

    static func `default`(fileManager: FileManager = .default) throws -> DatabasePaths {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = appSupport.appendingPathComponent("BuXiangBeiDanCi", isDirectory: true)
        let restoreDirectory = appDirectory.appendingPathComponent("Restore", isDirectory: true)
        return DatabasePaths(
            databaseDirectoryURL: appDirectory,
            databaseFileURL: appDirectory.appendingPathComponent("buxiangbeidanci.sqlite"),
            stagingDirectoryURL: restoreDirectory.appendingPathComponent("Staging", isDirectory: true),
            internalBackupsDirectoryURL: appDirectory.appendingPathComponent("Backups", isDirectory: true),
            pendingRestoreManifestURL: restoreDirectory.appendingPathComponent("pending-restore.json"),
            restoreResultURL: restoreDirectory.appendingPathComponent("restore-result.json")
        )
    }

    var databaseWALURL: URL {
        URL(fileURLWithPath: databaseFileURL.path + "-wal")
    }

    var databaseSHMURL: URL {
        URL(fileURLWithPath: databaseFileURL.path + "-shm")
    }

    func prepareDirectories(fileManager: FileManager) throws {
        try fileManager.createDirectory(at: databaseDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: internalBackupsDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: pendingRestoreManifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

struct PendingRestoreManifest: Codable, Sendable {
    let stagedBackupURL: URL
    let originalFilename: String
    let createdAt: Date
}

struct RestoreLaunchResult: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case succeeded
        case failed
    }

    let status: Status
    let message: String
    let createdAt: Date
}

struct BackupLaunchAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum BackupServiceError: LocalizedError {
    case invalidFileExtension
    case selectedLiveDatabase
    case invalidSQLiteFile
    case integrityCheckFailed(String)
    case missingRequiredTables([String])
    case missingMigrationMetadata
    case missingStagedBackup

    var errorDescription: String? {
        switch self {
        case .invalidFileExtension:
            return "请选择 `.sqlite` 备份文件。"
        case .selectedLiveDatabase:
            return "不能直接选择当前正在使用的词库文件作为恢复来源。"
        case .invalidSQLiteFile:
            return "所选文件不是可用的 SQLite 备份。"
        case .integrityCheckFailed(let details):
            return "备份文件校验失败：\(details)"
        case .missingRequiredTables(let tables):
            return "备份文件缺少必要数据表：\(tables.joined(separator: "、"))"
        case .missingMigrationMetadata:
            return "备份文件不包含可识别的迁移信息。"
        case .missingStagedBackup:
            return "待恢复的 staging 备份不存在。"
        }
    }
}

struct StartupRestoreHelper {
    let paths: DatabasePaths
    let fileManager: FileManager
    let migrator: DatabaseMigrator

    func applyPendingRestoreIfNeeded() throws {
        try paths.prepareDirectories(fileManager: fileManager)

        guard let manifest = try loadPendingRestoreManifest() else {
            return
        }

        do {
            try performRestore(using: manifest)
            try? writeRestoreResult(
                RestoreLaunchResult(
                    status: .succeeded,
                    message: "词库已从备份恢复，当前数据已被备份内容覆盖。",
                    createdAt: Date()
                )
            )
        } catch {
            try? writeRestoreResult(
                RestoreLaunchResult(
                    status: .failed,
                    message: "从备份恢复失败：\(error.localizedDescription)",
                    createdAt: Date()
                )
            )
        }

        cleanupPendingRestoreArtifacts(for: manifest)
    }

    func validateBackupFile(at url: URL, requireMigrationMetadata: Bool = true) throws {
        guard url.pathExtension.lowercased() == "sqlite" else {
            throw BackupServiceError.invalidFileExtension
        }

        guard fileManager.fileExists(atPath: url.path) else {
            throw BackupServiceError.invalidSQLiteFile
        }

        var configuration = Configuration()
        configuration.readonly = true

        let dbQueue: DatabaseQueue
        do {
            dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            throw BackupServiceError.invalidSQLiteFile
        }

        try dbQueue.read { db in
            let integrityResult = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            guard integrityResult == "ok" else {
                throw BackupServiceError.integrityCheckFailed(integrityResult ?? "未知错误")
            }

            let tableNames = Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))

            let requiredTables = ["capture_jobs", "words", "word_sources"]
            let missingTables = requiredTables.filter { !tableNames.contains($0) }
            guard missingTables.isEmpty else {
                throw BackupServiceError.missingRequiredTables(missingTables)
            }

            if requireMigrationMetadata && !tableNames.contains("grdb_migrations") {
                throw BackupServiceError.missingMigrationMetadata
            }
        }
    }

    private func performRestore(using manifest: PendingRestoreManifest) throws {
        guard fileManager.fileExists(atPath: manifest.stagedBackupURL.path) else {
            throw BackupServiceError.missingStagedBackup
        }

        try validateBackupFile(at: manifest.stagedBackupURL)

        let preRestoreBackupURL = try createPreRestoreBackupIfNeeded()
        let materializedRestoreURL = try migrateAndMaterializeStagingBackup(at: manifest.stagedBackupURL)

        do {
            try removeLiveDatabaseSidecars()
            try replaceLiveDatabase(with: materializedRestoreURL)
        } catch {
            try? fileManager.removeItemIfExists(at: materializedRestoreURL)
            if let preRestoreBackupURL {
                try restoreLiveDatabaseFromBackup(at: preRestoreBackupURL)
            }
            throw error
        }
    }

    private func createPreRestoreBackupIfNeeded() throws -> URL? {
        guard fileManager.fileExists(atPath: paths.databaseFileURL.path) else {
            return nil
        }

        let filename = "PreRestore-v\(BackupFileNaming.appVersion)-\(BackupFileNaming.timestampString()).sqlite"
        let backupURL = paths.internalBackupsDirectoryURL.appendingPathComponent(filename)
        try {
            var sourceConfiguration = Configuration()
            sourceConfiguration.readonly = true

            let source = try DatabaseQueue(path: paths.databaseFileURL.path, configuration: sourceConfiguration)
            let destination = try DatabaseQueue(path: backupURL.path)
            try source.backup(to: destination)
            try destination.inDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
        }()

        try fileManager.removeItemIfExists(at: URL(fileURLWithPath: backupURL.path + "-wal"))
        try fileManager.removeItemIfExists(at: URL(fileURLWithPath: backupURL.path + "-shm"))

        return backupURL
    }

    private func migrateAndMaterializeStagingBackup(at stagingURL: URL) throws -> URL {
        let stagingQueue = try DatabaseQueue(path: stagingURL.path)
        try migrator.migrate(stagingQueue)

        let materializedURL = paths.stagingDirectoryURL
            .appendingPathComponent("restored-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")

        let materializedQueue = try DatabaseQueue(path: materializedURL.path)
        try stagingQueue.backup(to: materializedQueue)

        return materializedURL
    }

    private func replaceLiveDatabase(with restoredDatabaseURL: URL) throws {
        if fileManager.fileExists(atPath: paths.databaseFileURL.path) {
            _ = try fileManager.replaceItemAt(paths.databaseFileURL, withItemAt: restoredDatabaseURL)
        } else {
            try fileManager.moveItem(at: restoredDatabaseURL, to: paths.databaseFileURL)
        }
    }

    private func restoreLiveDatabaseFromBackup(at backupURL: URL) throws {
        try removeLiveDatabaseSidecars()
        if fileManager.fileExists(atPath: paths.databaseFileURL.path) {
            try fileManager.removeItem(at: paths.databaseFileURL)
        }
        try fileManager.copyItem(at: backupURL, to: paths.databaseFileURL)
    }

    private func removeLiveDatabaseSidecars() throws {
        try fileManager.removeItemIfExists(at: paths.databaseWALURL)
        try fileManager.removeItemIfExists(at: paths.databaseSHMURL)
    }

    private func loadPendingRestoreManifest() throws -> PendingRestoreManifest? {
        guard fileManager.fileExists(atPath: paths.pendingRestoreManifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: paths.pendingRestoreManifestURL)
        return try JSONDecoder().decode(PendingRestoreManifest.self, from: data)
    }

    private func writeRestoreResult(_ result: RestoreLaunchResult) throws {
        let data = try JSONEncoder().encode(result)
        try data.write(to: paths.restoreResultURL, options: .atomic)
    }

    private func cleanupPendingRestoreArtifacts(for manifest: PendingRestoreManifest) {
        try? fileManager.removeItemIfExists(at: manifest.stagedBackupURL)
        try? fileManager.removeItemIfExists(at: paths.pendingRestoreManifestURL)
    }
}

@MainActor
final class BackupService: ObservableObject {
    static let shared = BackupService()

    @Published private(set) var isExporting = false
    @Published private(set) var isPreparingRestore = false
    @Published var launchAlert: BackupLaunchAlert?

    private let database: Database
    private let paths: DatabasePaths
    private let fileManager: FileManager
    private let restoreHelper: StartupRestoreHelper
    private var didLoadLaunchResult = false

    init(
        database: Database = .shared,
        paths: DatabasePaths? = nil,
        fileManager: FileManager = .default
    ) {
        let resolvedPaths = paths ?? (try! DatabasePaths.default(fileManager: fileManager))
        self.database = database
        self.paths = resolvedPaths
        self.fileManager = fileManager
        self.restoreHelper = StartupRestoreHelper(
            paths: resolvedPaths,
            fileManager: fileManager,
            migrator: Database.makeMigrator()
        )
    }

    var isBusy: Bool {
        isExporting || isPreparingRestore
    }

    func exportBackup(to destinationURL: URL) async throws {
        try database.exportConsistentSnapshot(to: destinationURL)
    }

    func stageRestore(from sourceURL: URL) throws {
        try paths.prepareDirectories(fileManager: fileManager)

        let standardizedSourceURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        guard standardizedSourceURL.pathExtension.lowercased() == "sqlite" else {
            throw BackupServiceError.invalidFileExtension
        }

        guard standardizedSourceURL.path != paths.databaseFileURL.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw BackupServiceError.selectedLiveDatabase
        }

        try clearPendingRestoreState()

        let stagedURL = paths.stagingDirectoryURL
            .appendingPathComponent("restore-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")

        do {
            try fileManager.copyItem(at: standardizedSourceURL, to: stagedURL)
            try restoreHelper.validateBackupFile(at: stagedURL)
            let manifest = PendingRestoreManifest(
                stagedBackupURL: stagedURL,
                originalFilename: standardizedSourceURL.lastPathComponent,
                createdAt: Date()
            )
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: paths.pendingRestoreManifestURL, options: .atomic)
        } catch {
            try? fileManager.removeItemIfExists(at: stagedURL)
            try? fileManager.removeItemIfExists(at: paths.pendingRestoreManifestURL)
            throw error
        }
    }

    func beginExportFlow() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.nameFieldStringValue = BackupFileNaming.defaultExportFilename
        panel.title = "导出备份"
        panel.message = "仅备份词库 SQLite 数据，不包含设置与 API Key。"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        isExporting = true
        defer { isExporting = false }

        do {
            try await exportBackup(to: destinationURL)
            presentAlert(
                title: "导出完成",
                message: "词库备份已导出为单个 `.sqlite` 文件。"
            )
        } catch {
            presentAlert(title: "导出失败", message: error.localizedDescription)
        }
    }

    func beginRestoreFlow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "从备份恢复"
        panel.message = "恢复会覆盖当前词库，不会导入设置或 API Key。"

        guard panel.runModal() == .OK, let sourceURL = panel.url else {
            return
        }

        isPreparingRestore = true
        defer { isPreparingRestore = false }

        do {
            try stageRestore(from: sourceURL)

            let confirmation = NSAlert()
            confirmation.messageText = "确认从备份恢复"
            confirmation.informativeText = "这会覆盖当前词库，应用将立即退出。重新打开后才会完成恢复，未备份的新数据会丢失。"
            confirmation.alertStyle = .warning
            confirmation.addButton(withTitle: "恢复并退出")
            confirmation.addButton(withTitle: "取消")

            if confirmation.runModal() == .alertFirstButtonReturn {
                NSApplication.shared.terminate(nil)
            } else {
                try clearPendingRestoreState()
            }
        } catch {
            presentAlert(title: "无法恢复", message: error.localizedDescription)
        }
    }

    func loadLaunchRestoreResultIfNeeded() {
        guard !didLoadLaunchResult else { return }
        didLoadLaunchResult = true

        guard fileManager.fileExists(atPath: paths.restoreResultURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: paths.restoreResultURL)
            let result = try JSONDecoder().decode(RestoreLaunchResult.self, from: data)
            try fileManager.removeItemIfExists(at: paths.restoreResultURL)

            let title = result.status == .succeeded ? "恢复完成" : "恢复失败"
            launchAlert = BackupLaunchAlert(title: title, message: result.message)
        } catch {
            try? fileManager.removeItemIfExists(at: paths.restoreResultURL)
        }
    }

    func clearLaunchAlert() {
        launchAlert = nil
    }

    private func clearPendingRestoreState() throws {
        if fileManager.fileExists(atPath: paths.pendingRestoreManifestURL.path) {
            let data = try Data(contentsOf: paths.pendingRestoreManifestURL)
            if let manifest = try? JSONDecoder().decode(PendingRestoreManifest.self, from: data) {
                try? fileManager.removeItemIfExists(at: manifest.stagedBackupURL)
            }
        }
        try fileManager.removeItemIfExists(at: paths.pendingRestoreManifestURL)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }
}

private enum BackupFileNaming {
    static var defaultExportFilename: String {
        "BuXiangBeiDanCi-Backup-v\(appVersion)-\(timestampString()).sqlite"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func timestampString(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private extension FileManager {
    func removeItemIfExists(at url: URL) throws {
        guard fileExists(atPath: url.path) else { return }
        try removeItem(at: url)
    }
}
