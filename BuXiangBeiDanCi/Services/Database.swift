import Foundation
import GRDB
import os.log

/// Database manager using GRDB with DatabasePool (WAL mode)
final class Database {

    static let shared = Database()

    typealias WriterFactory = (URL) throws -> any DatabaseWriter

    private let dbWriter: any DatabaseWriter
    private let paths: DatabasePaths?
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.blackkingbar.buxiangbeidanci", category: "database")

    private init() {
        do {
            let fileManager = FileManager.default
            let paths = try DatabasePaths.default(fileManager: fileManager)
            self.fileManager = fileManager
            self.paths = paths
            try paths.prepareDirectories(fileManager: fileManager)

            let restoreHelper = StartupRestoreHelper(
                paths: paths,
                fileManager: fileManager,
                migrator: Self.makeMigrator()
            )
            try restoreHelper.applyPendingRestoreIfNeeded()

            dbWriter = try Self.createFileBasedWriter(at: paths.databaseFileURL)
        } catch {
            logger.critical("❌ Failed to setup database: \(error)")
            fatalError("Database setup failed: \(error)")
        }
        do {
            try Self.makeMigrator().migrate(dbWriter)
            try ensureInboxExistsSync()
        } catch {
            logger.critical("❌ Failed to migrate database: \(error)")
            fatalError("Database migration failed: \(error)")
        }
        logger.info("✅ Database setup complete")
    }

    init(
        paths: DatabasePaths,
        fileManager: FileManager = .default,
        writerFactory: WriterFactory? = nil
    ) throws {
        self.fileManager = fileManager
        self.paths = paths

        try paths.prepareDirectories(fileManager: fileManager)

        let restoreHelper = StartupRestoreHelper(
            paths: paths,
            fileManager: fileManager,
            migrator: Self.makeMigrator()
        )
        try restoreHelper.applyPendingRestoreIfNeeded()

        let resolvedWriterFactory = writerFactory ?? Self.createFileBasedWriter(at:)
        self.dbWriter = try resolvedWriterFactory(paths.databaseFileURL)
        try Self.makeMigrator().migrate(dbWriter)
        try ensureInboxExistsSync()
    }

    /// Internal init for testing with an in-memory database
    init(writer: any DatabaseWriter) throws {
        self.fileManager = .default
        self.paths = nil
        self.dbWriter = writer
        try Self.makeMigrator().migrate(dbWriter)
        try ensureInboxExistsSync()
    }

    var databaseDirectoryURL: URL? {
        paths?.databaseDirectoryURL
    }

    var databaseFileURL: URL? {
        paths?.databaseFileURL
    }

    func exportConsistentSnapshot(to destinationURL: URL) throws {
        let parentDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        let temporaryURL = parentDirectory
            .appendingPathComponent(".backup-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")

        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }

        do {
            try {
                let destinationWriter = try DatabaseQueue(path: temporaryURL.path)
                try dbWriter.backup(to: destinationWriter)
                try destinationWriter.inDatabase { db in
                    try db.execute(sql: "PRAGMA journal_mode = DELETE")
                }
            }()

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    private static func createFileBasedWriter(at databaseFileURL: URL) throws -> any DatabaseWriter {
        try DatabasePool(path: databaseFileURL.path)
    }

    private func ensureInboxExistsSync() throws {
        try dbWriter.write { db in
            let exists = try Folder.filter(Column("isSystem") == true).fetchCount(db) > 0
            if !exists {
                try db.execute(
                    sql: "INSERT INTO folders (name, isSystem, sortOrder, createdAt) VALUES ('Inbox', 1, 0, ?)",
                    arguments: [Date()]
                )
            }
        }
    }
    
    // MARK: - Migrations
    
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        // v1: Initial schema
        migrator.registerMigration("v1_initial") { db in
            // Capture jobs table
            try db.create(table: "capture_jobs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("selectedText", .text).notNull()
                t.column("normalizedText", .text).notNull()
                t.column("sentence", .text)  // The full sentence containing the word
                t.column("sourceApp", .text).notNull()
                t.column("bundleId", .text).notNull()
                t.column("sourceUrl", .text)
                t.column("sourceTitle", .text)
                t.column("sourceStatus", .text).notNull().defaults(to: "partial")
                t.column("captureMethod", .text).notNull().defaults(to: "service")
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("needsReview", .boolean).notNull().defaults(to: false)
                t.column("errorMessage", .text)
                t.column("errorCategory", .text)
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("processedAt", .datetime)
            }
            
            // Words table
            try db.create(table: "words") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("lemma", .text).notNull().unique(onConflict: .ignore).collate(.nocase)
                t.column("phonetic", .text)
                t.column("definition", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("reviewCount", .integer).notNull().defaults(to: 0)
                t.column("nextReviewAt", .datetime)
                t.column("familiarity", .integer).notNull().defaults(to: 0)
            }
            
            // Word sources table
            try db.create(table: "word_sources") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("wordId", .integer).notNull()
                    .references("words", onDelete: .cascade)
                t.column("captureJobId", .integer)
                    .references("capture_jobs", onDelete: .setNull)
                t.column("surfaceForm", .text).notNull()
                t.column("sentence", .text).notNull()
                t.column("sentenceTranslation", .text)
                t.column("sentenceSource", .text).notNull()
                t.column("sourceApp", .text).notNull()
                t.column("bundleId", .text).notNull()
                t.column("sourceUrl", .text)
                t.column("sourceTitle", .text)
                t.column("sourceStatus", .text).notNull()
                t.column("aiModel", .text)
                t.column("aiLatencyMs", .integer)
                t.column("needsReview", .boolean).notNull().defaults(to: false)
                t.column("capturedAt", .datetime).notNull()
            }
            
            // Indexes
            try db.create(index: "idx_jobs_status", on: "capture_jobs", columns: ["status"])
            try db.create(index: "idx_jobs_created", on: "capture_jobs", columns: ["createdAt"])
            try db.create(index: "idx_sources_word_id", on: "word_sources", columns: ["wordId"])
            try db.create(index: "idx_sources_needs_review", on: "word_sources", columns: ["needsReview"])
        }

        // v2: add needsReview to capture_jobs (for older databases)
        migrator.registerMigration("v2_capture_jobs_needs_review") { db in
            let needsReviewColumnCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_table_info('capture_jobs') WHERE name = ?",
                arguments: ["needsReview"]
            ) ?? 0

            if needsReviewColumnCount == 0 {
                try db.alter(table: "capture_jobs") { t in
                    t.add(column: "needsReview", .boolean).notNull().defaults(to: false)
                }
            }
        }
        
        migrator.registerMigration("v3_word_in_translation") { db in
            let colCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_table_info('word_sources') WHERE name = ?",
                arguments: ["wordInTranslation"]
            ) ?? 0

            if colCount == 0 {
                try db.alter(table: "word_sources") { t in
                    t.add(column: "wordInTranslation", .text)
                }
            }
        }
        
        // v4: Folder system
        migrator.registerMigration("v4_folders") { db in
            try db.create(table: "folders") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().collate(.nocase)
                t.column("isSystem", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(index: "idx_folders_name", on: "folders", columns: ["name"], unique: true)

            try db.execute(
                sql: "INSERT INTO folders (name, isSystem, sortOrder, createdAt) VALUES ('Inbox', 1, 0, ?)",
                arguments: [Date()]
            )

            let inboxId = db.lastInsertedRowID
            try db.alter(table: "words") { t in
                t.add(column: "folderId", .integer)
                    .notNull()
                    .defaults(to: inboxId)
                    .references("folders", onDelete: .restrict)
            }

            try db.create(index: "idx_words_folder_id", on: "words", columns: ["folderId"])
        }

        return migrator
    }
    
    // MARK: - Capture Jobs CRUD
    
    func saveCaptureJob(_ job: CaptureJob) async throws -> CaptureJob {
        try await dbWriter.write { db in
            var mutableJob = job
            try mutableJob.insert(db)
            return mutableJob
        }
    }
    
    func updateCaptureJob(_ job: CaptureJob) async throws {
        try await dbWriter.write { db in
            try job.update(db)
        }
    }
    
    func getCaptureJob(id: Int64) async throws -> CaptureJob? {
        try await dbWriter.read { db in
            try CaptureJob.fetchOne(db, key: id)
        }
    }
    
    func getRecentCaptureJobs(limit: Int = 50) async throws -> [CaptureJob] {
        try await dbWriter.read { db in
            try CaptureJob
                .order(CaptureJob.Columns.createdAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
    
    func getJobStatusCounts() async throws -> [String: Int] {
        try await dbWriter.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT status, COUNT(*) AS cnt FROM capture_jobs GROUP BY status"
            )
            var result: [String: Int] = [:]
            for row in rows {
                let status: String = row["status"]
                let count: Int = row["cnt"]
                result[status] = count
            }
            return result
        }
    }

    func getPendingJobs() async throws -> [CaptureJob] {
        try await dbWriter.read { db in
            try CaptureJob
                .filter(CaptureJob.Columns.status == CaptureJob.JobStatus.pending.rawValue)
                .order(CaptureJob.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    func getActiveJobs() async throws -> [CaptureJob] {
        try await dbWriter.read { db in
            try CaptureJob.fetchAll(
                db,
                sql: """
                SELECT *
                FROM capture_jobs
                WHERE status IN (?, ?)
                ORDER BY createdAt ASC
                """,
                arguments: [
                    CaptureJob.JobStatus.pending.rawValue,
                    CaptureJob.JobStatus.processing.rawValue
                ]
            )
        }
    }
    
    // MARK: - Words CRUD
    
    func saveWord(_ word: Word) async throws -> Word {
        try await dbWriter.write { db in
            var mutableWord = word
            try mutableWord.insert(db)
            return mutableWord
        }
    }

    func updateWord(_ word: Word) async throws {
        try await dbWriter.write { db in
            try word.update(db)
        }
    }

    func deleteWord(id: Int64) async throws {
        _ = try await dbWriter.write { db in
            try Word.deleteOne(db, id: id)
        }
    }

    func deleteWords(ids: Set<Int64>) async throws {
        guard !ids.isEmpty else { return }
        _ = try await dbWriter.write { db in
            try Word.filter(ids: ids).deleteAll(db)
        }
    }

    func getWordWithSources(id: Int64) async throws -> (Word, [WordSource])? {
        try await dbWriter.read { db in
            guard let word = try Word.fetchOne(db, key: id) else { return nil }
            let sources = try WordSource
                .filter(Column("wordId") == id)
                .fetchAll(db)
            return (word, sources)
        }
    }

    func restoreWord(_ word: Word, sources: [WordSource]) async throws -> Word {
        try await dbWriter.write { db in
            if let existing = try Word.filter(Column("lemma").collating(.nocase) == word.lemma).fetchOne(db) {
                // Lemma already exists — merge sources into existing word
                for var source in sources {
                    source.id = nil
                    source.wordId = existing.id!
                    try source.insert(db)
                }
                return existing
            } else {
                var newWord = word
                newWord.id = nil
                try newWord.insert(db)
                guard let newId = newWord.id else {
                    throw NSError(domain: "Database", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to restore word"])
                }
                for var source in sources {
                    source.id = nil
                    source.wordId = newId
                    try source.insert(db)
                }
                return newWord
            }
        }
    }

    func getWord(id: Int64) async throws -> Word? {
        try await dbWriter.read { db in
            try Word.fetchOne(db, key: id)
        }
    }

    func getWord(lemma: String) async throws -> Word? {
        try await dbWriter.read { db in
            try Word.filter(Column("lemma").collating(.nocase) == lemma).fetchOne(db)
        }
    }
    
    func getAllWords() async throws -> [Word] {
        try await dbWriter.read { db in
            try Word.order(Column("createdAt").desc).fetchAll(db)
        }
    }
    
    // MARK: - Word Sources CRUD
    
    func saveWordSource(_ source: WordSource) async throws -> WordSource {
        try await dbWriter.write { db in
            var mutableSource = source
            try mutableSource.insert(db)
            return mutableSource
        }
    }
    
    func getWordForCaptureJob(jobId: Int64) async throws -> Word? {
        try await dbWriter.read { db in
            let source = try WordSource
                .filter(Column("captureJobId") == jobId)
                .fetchOne(db)
            guard let source else { return nil }
            return try Word.fetchOne(db, key: source.wordId)
        }
    }

    func getSourcesForWord(wordId: Int64) async throws -> [WordSource] {
        try await dbWriter.read { db in
            try WordSource
                .filter(Column("wordId") == wordId)
                .order(Column("capturedAt").desc)
                .fetchAll(db)
        }
    }

    func getWordSourceForJob(captureJobId: Int64) async throws -> WordSource? {
        try await dbWriter.read { db in
            try WordSource
                .filter(Column("captureJobId") == captureJobId)
                .fetchOne(db)
        }
    }

    func updateWordSource(_ source: WordSource) async throws {
        try await dbWriter.write { db in
            try source.update(db)
        }
    }

    func deleteWordSource(id: Int64) async throws {
        _ = try await dbWriter.write { db in
            try WordSource.deleteOne(db, id: id)
        }
    }

    // MARK: - Folders CRUD

    func ensureInboxExists() async throws {
        try await dbWriter.write { db in
            let exists = try Folder.filter(Column("isSystem") == true).fetchCount(db) > 0
            if !exists {
                try db.execute(
                    sql: "INSERT INTO folders (name, isSystem, sortOrder, createdAt) VALUES ('Inbox', 1, 0, ?)",
                    arguments: [Date()]
                )
            }
        }
    }

    func getAllFolders() async throws -> [Folder] {
        try await dbWriter.read { db in
            try Folder.order(Column("sortOrder").asc).fetchAll(db)
        }
    }

    func getInboxFolder() async throws -> Folder {
        try await dbWriter.read { db in
            guard let inbox = try Folder.filter(Column("isSystem") == true).fetchOne(db) else {
                fatalError("Inbox folder missing from database")
            }
            return inbox
        }
    }

    func createFolder(name: String) async throws -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "Database", code: 1, userInfo: [NSLocalizedDescriptionKey: "Folder name cannot be empty"])
        }
        return try await dbWriter.write { db in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM folders") ?? 0
            var folder = Folder(
                id: nil,
                name: trimmed,
                isSystem: false,
                sortOrder: maxOrder + 1,
                createdAt: Date()
            )
            try folder.insert(db)
            return folder
        }
    }

    func renameFolder(_ folder: Folder, to newName: String) async throws {
        guard !folder.isSystem else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await dbWriter.write { db in
            var updated = folder
            updated.name = trimmed
            try updated.update(db)
        }
    }

    func deleteFolder(_ folder: Folder) async throws {
        guard !folder.isSystem else { return }
        try await dbWriter.write { db in
            let inbox = try Folder.filter(Column("isSystem") == true).fetchOne(db)
            guard let inboxId = inbox?.id else { return }
            try db.execute(
                sql: "UPDATE words SET folderId = ? WHERE folderId = ?",
                arguments: [inboxId, folder.id]
            )
            try folder.delete(db)
        }
    }

    func moveWord(_ wordId: Int64, toFolder folderId: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE words SET folderId = ? WHERE id = ?",
                arguments: [folderId, wordId]
            )
        }
    }

    func moveWords(_ wordIds: Set<Int64>, toFolder folderId: Int64) async throws {
        try await dbWriter.write { db in
            for wordId in wordIds {
                try db.execute(
                    sql: "UPDATE words SET folderId = ? WHERE id = ?",
                    arguments: [folderId, wordId]
                )
            }
        }
    }
}
