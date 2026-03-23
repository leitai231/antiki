import Foundation
import GRDB
@testable import BuXiangBeiDanCi

/// Type alias to disambiguate our Database from GRDB's Database
typealias AppDatabase = BuXiangBeiDanCi.Database

/// Creates an in-memory Database instance for testing.
/// Each call returns a fresh, migrated database.
enum TestDatabase {
    static func make() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: .init())
        return try AppDatabase(writer: queue)
    }

    static func makeFileBacked(paths: DatabasePaths) throws -> AppDatabase {
        try AppDatabase(paths: paths)
    }
}

struct TestAppFiles {
    let rootURL: URL
    let paths: DatabasePaths

    init(name: String = UUID().uuidString, fileManager: FileManager = .default) throws {
        self.rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("BuXiangBeiDanCiTests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)

        self.paths = DatabasePaths(
            databaseDirectoryURL: rootURL.appendingPathComponent("Database", isDirectory: true),
            databaseFileURL: rootURL
                .appendingPathComponent("Database", isDirectory: true)
                .appendingPathComponent("buxiangbeidanci.sqlite"),
            stagingDirectoryURL: rootURL
                .appendingPathComponent("Restore", isDirectory: true)
                .appendingPathComponent("Staging", isDirectory: true),
            internalBackupsDirectoryURL: rootURL
                .appendingPathComponent("Backups", isDirectory: true),
            pendingRestoreManifestURL: rootURL
                .appendingPathComponent("Restore", isDirectory: true)
                .appendingPathComponent("pending-restore.json"),
            restoreResultURL: rootURL
                .appendingPathComponent("Restore", isDirectory: true)
                .appendingPathComponent("restore-result.json")
        )

        try paths.prepareDirectories(fileManager: fileManager)
    }

    func cleanup(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try fileManager.removeItem(at: rootURL)
    }
}
