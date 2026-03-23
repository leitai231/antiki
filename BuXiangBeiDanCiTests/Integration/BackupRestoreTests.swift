import XCTest
import GRDB
@testable import BuXiangBeiDanCi

@MainActor
final class BackupRestoreTests: XCTestCase {

    private var appFiles: TestAppFiles!
    private var db: AppDatabase!
    private var backupService: BackupService!

    override func setUpWithError() throws {
        appFiles = try TestAppFiles()
        db = try TestDatabase.makeFileBacked(paths: appFiles.paths)
        backupService = BackupService(database: db, paths: appFiles.paths)
    }

    override func tearDownWithError() throws {
        backupService = nil
        db = nil
        try appFiles.cleanup()
        appFiles = nil
    }

    func testExportBackupProducesSingleSQLiteSnapshotWithCurrentData() async throws {
        try await seedCurrentDatabase(withLemma: "alpha")
        let exportURL = appFiles.rootURL.appendingPathComponent("export.sqlite")

        try await backupService.exportBackup(to: exportURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path + "-shm"))

        let exportedQueue = try DatabaseQueue(path: exportURL.path)
        try Database.makeMigrator().migrate(exportedQueue)

        try exportedQueue.inDatabase { db in
            let words = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM words")
            let sources = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM word_sources")
            let jobs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM capture_jobs")
            let folders = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folders")
            XCTAssertEqual(words, 1)
            XCTAssertEqual(sources, 1)
            XCTAssertEqual(jobs, 1)
            XCTAssertEqual(folders, 1)
        }
    }

    func testStageRestoreRejectsNonSQLiteFile() throws {
        let invalidURL = appFiles.rootURL.appendingPathComponent("not-a-backup.txt")
        try XCTUnwrap("hello".data(using: .utf8)).write(to: invalidURL)

        XCTAssertThrowsError(try backupService.stageRestore(from: invalidURL)) { error in
            XCTAssertEqual(error.localizedDescription, BackupServiceError.invalidFileExtension.localizedDescription)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: appFiles.paths.pendingRestoreManifestURL.path))
    }

    func testStageRestoreRejectsCorruptSQLiteFile() throws {
        let invalidURL = appFiles.rootURL.appendingPathComponent("broken.sqlite")
        try XCTUnwrap("not a real sqlite file".data(using: .utf8)).write(to: invalidURL)

        XCTAssertThrowsError(try backupService.stageRestore(from: invalidURL)) { error in
            XCTAssertEqual(error.localizedDescription, BackupServiceError.invalidSQLiteFile.localizedDescription)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: appFiles.paths.pendingRestoreManifestURL.path))
    }

    func testValidateBackupFileAcceptsReadOnlySQLiteBackup() async throws {
        try await seedCurrentDatabase(withLemma: "readonly")

        let exportURL = appFiles.rootURL.appendingPathComponent("readonly.sqlite")
        try await backupService.exportBackup(to: exportURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: exportURL.path)

        let helper = StartupRestoreHelper(
            paths: appFiles.paths,
            fileManager: .default,
            migrator: Database.makeMigrator()
        )

        XCTAssertNoThrow(try helper.validateBackupFile(at: exportURL))
    }

    func testStageRestoreCopiesToStagingWithoutMutatingSource() async throws {
        let sourceFiles = try TestAppFiles()
        defer { try? sourceFiles.cleanup() }

        let sourceDB = try TestDatabase.makeFileBacked(paths: sourceFiles.paths)
        let sourceService = BackupService(database: sourceDB, paths: sourceFiles.paths)
        try await seed(database: sourceDB, withLemma: "staged")

        let exportURL = sourceFiles.rootURL.appendingPathComponent("source.sqlite")
        try await sourceService.exportBackup(to: exportURL)
        try assertValidSQLiteBackup(at: exportURL)
        let originalData = try Data(contentsOf: exportURL)

        try backupService.stageRestore(from: exportURL)

        let manifestData = try Data(contentsOf: appFiles.paths.pendingRestoreManifestURL)
        let manifest = try JSONDecoder().decode(PendingRestoreManifest.self, from: manifestData)

        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.stagedBackupURL.path))
        XCTAssertEqual(try Data(contentsOf: exportURL), originalData)
    }

    func testStartupRestoreReplacesLiveDatabaseAndCreatesPreRestoreBackup() async throws {
        try await seedCurrentDatabase(withLemma: "alpha")

        let sourceFiles = try TestAppFiles()
        defer { try? sourceFiles.cleanup() }

        let sourceDB = try TestDatabase.makeFileBacked(paths: sourceFiles.paths)
        let sourceService = BackupService(database: sourceDB, paths: sourceFiles.paths)
        try await seed(database: sourceDB, withLemma: "beta")

        let exportURL = sourceFiles.rootURL.appendingPathComponent("restore-source.sqlite")
        try await sourceService.exportBackup(to: exportURL)
        try assertValidSQLiteBackup(at: exportURL)

        try backupService.stageRestore(from: exportURL)

        backupService = nil
        db = nil

        let restoredDB = try TestDatabase.makeFileBacked(paths: appFiles.paths)
        let allWords = try await restoredDB.getAllWords()
        XCTAssertEqual(allWords.map(\.lemma), ["beta"])

        let backupFiles = try FileManager.default.contentsOfDirectory(at: appFiles.paths.internalBackupsDirectoryURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(backupFiles.count, 1)
        XCTAssertTrue(backupFiles[0].lastPathComponent.hasPrefix("PreRestore-"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: appFiles.paths.pendingRestoreManifestURL.path))
    }

    func testPendingRestoreIsAppliedBeforeWriterCreation() async throws {
        try await seedCurrentDatabase(withLemma: "alpha")

        let sourceFiles = try TestAppFiles()
        defer { try? sourceFiles.cleanup() }

        let sourceDB = try TestDatabase.makeFileBacked(paths: sourceFiles.paths)
        let sourceService = BackupService(database: sourceDB, paths: sourceFiles.paths)
        try await seed(database: sourceDB, withLemma: "beta")

        let exportURL = sourceFiles.rootURL.appendingPathComponent("ordered.sqlite")
        try await sourceService.exportBackup(to: exportURL)
        try assertValidSQLiteBackup(at: exportURL)
        try backupService.stageRestore(from: exportURL)

        backupService = nil
        db = nil

        let orderedDB = try AppDatabase(
            paths: appFiles.paths,
            writerFactory: { url in
                let queue = try DatabaseQueue(path: url.path)
                let lemmas = try queue.inDatabase { db in
                    try String.fetchAll(db, sql: "SELECT lemma FROM words ORDER BY lemma ASC")
                }
                XCTAssertEqual(lemmas, ["beta"])
                return try DatabasePool(path: url.path)
            }
        )

        let allWords = try await orderedDB.getAllWords()
        XCTAssertEqual(allWords.map(\.lemma), ["beta"])
    }

    func testStartupRestoreFailureKeepsCurrentDatabaseUntouched() async throws {
        try await seedCurrentDatabase(withLemma: "alpha")

        let missingStagingURL = appFiles.paths.stagingDirectoryURL.appendingPathComponent("missing.sqlite")
        let manifest = PendingRestoreManifest(
            stagedBackupURL: missingStagingURL,
            originalFilename: "missing.sqlite",
            createdAt: Date()
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: appFiles.paths.pendingRestoreManifestURL, options: .atomic)

        backupService = nil
        db = nil

        let reopenedDB = try TestDatabase.makeFileBacked(paths: appFiles.paths)
        let allWords = try await reopenedDB.getAllWords()
        XCTAssertEqual(allWords.map(\.lemma), ["alpha"])

        let resultData = try Data(contentsOf: appFiles.paths.restoreResultURL)
        let result = try JSONDecoder().decode(RestoreLaunchResult.self, from: resultData)
        XCTAssertEqual(result.status, .failed)
    }

    func testStartupRestoreIgnoresCleanupFailureAfterSuccessfulRestore() async throws {
        try await seedCurrentDatabase(withLemma: "alpha")

        let sourceFiles = try TestAppFiles()
        defer { try? sourceFiles.cleanup() }

        let sourceDB = try TestDatabase.makeFileBacked(paths: sourceFiles.paths)
        let sourceService = BackupService(database: sourceDB, paths: sourceFiles.paths)
        try await seed(database: sourceDB, withLemma: "beta")

        let exportURL = sourceFiles.rootURL.appendingPathComponent("cleanup.sqlite")
        try await sourceService.exportBackup(to: exportURL)
        try backupService.stageRestore(from: exportURL)

        let manifestData = try Data(contentsOf: appFiles.paths.pendingRestoreManifestURL)
        let manifest = try JSONDecoder().decode(PendingRestoreManifest.self, from: manifestData)

        backupService = nil
        db = nil

        let fileManager = CleanupFailingFileManager(blockedRemovalPaths: [manifest.stagedBackupURL.path])
        let helper = StartupRestoreHelper(
            paths: appFiles.paths,
            fileManager: fileManager,
            migrator: Database.makeMigrator()
        )

        XCTAssertNoThrow(try helper.applyPendingRestoreIfNeeded())

        let queue = try DatabaseQueue(path: appFiles.paths.databaseFileURL.path)
        let lemmas = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT lemma FROM words ORDER BY lemma ASC")
        }
        XCTAssertEqual(lemmas, ["beta"])

        let resultData = try Data(contentsOf: appFiles.paths.restoreResultURL)
        let result = try JSONDecoder().decode(RestoreLaunchResult.self, from: resultData)
        XCTAssertEqual(result.status, .succeeded)

        XCTAssertFalse(FileManager.default.fileExists(atPath: appFiles.paths.pendingRestoreManifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.stagedBackupURL.path))
    }

    func testLegacyBackupIsMigratedDuringRestore() async throws {
        try await seedCurrentDatabase(withLemma: "current")

        let legacyBackupURL = appFiles.rootURL.appendingPathComponent("legacy.sqlite")
        try makeLegacyV3Backup(at: legacyBackupURL)
        try backupService.stageRestore(from: legacyBackupURL)

        backupService = nil
        db = nil

        let restoredDB = try TestDatabase.makeFileBacked(paths: appFiles.paths)
        let inbox = try await restoredDB.getInboxFolder()
        let allWords = try await restoredDB.getAllWords()

        XCTAssertEqual(allWords.map(\.lemma), ["legacy"])
        XCTAssertEqual(allWords.first?.folderId, inbox.id)
    }

    private func seedCurrentDatabase(withLemma lemma: String) async throws {
        try await seed(database: db, withLemma: lemma)
    }

    private func seed(database: AppDatabase, withLemma lemma: String) async throws {
        let job = try await database.saveCaptureJob(
            CaptureJob(
                id: nil,
                selectedText: lemma,
                normalizedText: lemma,
                sentence: "This is \(lemma).",
                sourceApp: "Tests",
                bundleId: "tests.bundle",
                sourceUrl: nil,
                sourceTitle: nil,
                sourceStatus: "resolved",
                captureMethod: "test",
                status: .completed,
                needsReview: false,
                errorMessage: nil,
                errorCategory: nil,
                retryCount: 0,
                createdAt: Date(),
                processedAt: Date()
            )
        )

        let inbox = try await database.getInboxFolder()
        let word = try await database.saveWord(
            Word(
                id: nil,
                lemma: lemma,
                phonetic: nil,
                definition: "定义 \(lemma)",
                createdAt: Date(),
                updatedAt: Date(),
                reviewCount: 0,
                nextReviewAt: nil,
                familiarity: 0,
                folderId: inbox.id!
            )
        )

        _ = try await database.saveWordSource(
            WordSource(
                id: nil,
                wordId: word.id!,
                captureJobId: job.id!,
                surfaceForm: lemma,
                sentence: "This is \(lemma).",
                sentenceTranslation: "这是 \(lemma)。",
                wordInTranslation: lemma,
                sentenceSource: "selected",
                sourceApp: "Tests",
                bundleId: "tests.bundle",
                sourceUrl: nil,
                sourceTitle: nil,
                sourceStatus: "resolved",
                aiModel: "test-model",
                aiLatencyMs: 1,
                needsReview: false,
                capturedAt: Date()
            )
        )
    }

    private func makeLegacyV3Backup(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                )
                """)
            try db.execute(sql: """
                CREATE TABLE capture_jobs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    selectedText TEXT NOT NULL,
                    normalizedText TEXT NOT NULL,
                    sentence TEXT,
                    sourceApp TEXT NOT NULL,
                    bundleId TEXT NOT NULL,
                    sourceUrl TEXT,
                    sourceTitle TEXT,
                    sourceStatus TEXT NOT NULL DEFAULT 'partial',
                    captureMethod TEXT NOT NULL DEFAULT 'service',
                    status TEXT NOT NULL DEFAULT 'pending',
                    needsReview INTEGER NOT NULL DEFAULT 0,
                    errorMessage TEXT,
                    errorCategory TEXT,
                    retryCount INTEGER NOT NULL DEFAULT 0,
                    createdAt TEXT NOT NULL,
                    processedAt TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE words (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    lemma TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    phonetic TEXT,
                    definition TEXT NOT NULL,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    reviewCount INTEGER NOT NULL DEFAULT 0,
                    nextReviewAt TEXT,
                    familiarity INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE word_sources (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    wordId INTEGER NOT NULL REFERENCES words ON DELETE CASCADE,
                    captureJobId INTEGER REFERENCES capture_jobs ON DELETE SET NULL,
                    surfaceForm TEXT NOT NULL,
                    sentence TEXT NOT NULL,
                    sentenceTranslation TEXT,
                    sentenceSource TEXT NOT NULL,
                    sourceApp TEXT NOT NULL,
                    bundleId TEXT NOT NULL,
                    sourceUrl TEXT,
                    sourceTitle TEXT,
                    sourceStatus TEXT NOT NULL,
                    aiModel TEXT,
                    aiLatencyMs INTEGER,
                    needsReview INTEGER NOT NULL DEFAULT 0,
                    capturedAt TEXT NOT NULL,
                    wordInTranslation TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_jobs_status ON capture_jobs(status)")
            try db.execute(sql: "CREATE INDEX idx_jobs_created ON capture_jobs(createdAt)")
            try db.execute(sql: "CREATE INDEX idx_sources_word_id ON word_sources(wordId)")
            try db.execute(sql: "CREATE INDEX idx_sources_needs_review ON word_sources(needsReview)")

            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v1_initial')")
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v2_capture_jobs_needs_review')")
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v3_word_in_translation')")

            try db.execute(
                sql: """
                INSERT INTO capture_jobs (
                    selectedText, normalizedText, sentence, sourceApp, bundleId,
                    sourceStatus, captureMethod, status, needsReview, retryCount, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "legacy",
                    "legacy",
                    "Legacy sentence.",
                    "Tests",
                    "tests.bundle",
                    "resolved",
                    "test",
                    "completed",
                    0,
                    0,
                    Date()
                ]
            )

            try db.execute(
                sql: """
                INSERT INTO words (
                    lemma, phonetic, definition, createdAt, updatedAt, reviewCount, familiarity
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["legacy", nil, "旧词库定义", Date(), Date(), 0, 0]
            )

            try db.execute(
                sql: """
                INSERT INTO word_sources (
                    wordId, captureJobId, surfaceForm, sentence, sentenceTranslation,
                    sentenceSource, sourceApp, bundleId, sourceStatus, aiModel,
                    aiLatencyMs, needsReview, capturedAt, wordInTranslation
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [1, 1, "legacy", "Legacy sentence.", "旧句子。", "selected", "Tests", "tests.bundle", "resolved", "test-model", 1, 0, Date(), "legacy"]
            )
        }
    }

    private func assertValidSQLiteBackup(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.inDatabase { db in
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            XCTAssertEqual(result, "ok")
        }
    }
}

private final class CleanupFailingFileManager: FileManager {
    private let blockedRemovalPaths: Set<String>

    init(blockedRemovalPaths: Set<String>) {
        self.blockedRemovalPaths = blockedRemovalPaths
        super.init()
    }

    override func removeItem(at url: URL) throws {
        if blockedRemovalPaths.contains(url.path) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}
