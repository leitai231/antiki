import XCTest
import GRDB
@testable import BuXiangBeiDanCi

final class DatabaseTests: XCTestCase {

    private var db: AppDatabase!

    override func setUpWithError() throws {
        db = try TestDatabase.make()
    }

    // MARK: - Migrations

    func testMigrationsCreateAllTables() async throws {
        let jobs = try await db.getRecentCaptureJobs(limit: 10)
        XCTAssertTrue(jobs.isEmpty)

        let words = try await db.getAllWords()
        XCTAssertTrue(words.isEmpty)

        let folders = try await db.getAllFolders()
        XCTAssertFalse(folders.isEmpty, "Inbox folder should exist after migration")
    }

    func testInboxFolderExistsAfterMigration() async throws {
        let inbox = try await db.getInboxFolder()
        XCTAssertEqual(inbox.name, "Inbox")
        XCTAssertTrue(inbox.isSystem)
    }

    // MARK: - CaptureJob CRUD

    func testSaveAndFetchCaptureJob() async throws {
        let job = TestFixtures.makeCaptureJob()
        let saved = try await db.saveCaptureJob(job)

        XCTAssertNotNil(saved.id)

        let fetched = try await db.getCaptureJob(id: saved.id!)
        XCTAssertEqual(fetched?.selectedText, "running")
        XCTAssertEqual(fetched?.status, .pending)
    }

    func testUpdateCaptureJob() async throws {
        var job = try await db.saveCaptureJob(TestFixtures.makeCaptureJob())
        job.status = .completed
        job.processedAt = Date()
        try await db.updateCaptureJob(job)

        let fetched = try await db.getCaptureJob(id: job.id!)
        XCTAssertEqual(fetched?.status, .completed)
    }

    func testGetPendingJobs() async throws {
        _ = try await db.saveCaptureJob(TestFixtures.makeCaptureJob(status: .pending))
        _ = try await db.saveCaptureJob(TestFixtures.makeCaptureJob(selectedText: "jumping", status: .completed))

        let pending = try await db.getPendingJobs()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.selectedText, "running")
    }

    func testJobStatusCounts() async throws {
        _ = try await db.saveCaptureJob(TestFixtures.makeCaptureJob(status: .pending))
        _ = try await db.saveCaptureJob(TestFixtures.makeCaptureJob(selectedText: "a", status: .pending))
        _ = try await db.saveCaptureJob(TestFixtures.makeCaptureJob(selectedText: "b", status: .completed))

        let counts = try await db.getJobStatusCounts()
        XCTAssertEqual(counts["pending"], 2)
        XCTAssertEqual(counts["completed"], 1)
    }

    // MARK: - Word CRUD

    func testSaveAndFetchWord() async throws {
        let inbox = try await db.getInboxFolder()
        let word = Word(
            id: nil, lemma: "run", phonetic: "/rʌn/",
            definition: "跑步\nto run",
            createdAt: Date(), updatedAt: Date(),
            reviewCount: 0, nextReviewAt: nil, familiarity: 0,
            folderId: inbox.id!
        )
        let saved = try await db.saveWord(word)
        XCTAssertNotNil(saved.id)

        let fetched = try await db.getWord(id: saved.id!)
        XCTAssertEqual(fetched?.lemma, "run")
    }

    func testWordLemmaUniqueCaseInsensitive() async throws {
        let inbox = try await db.getInboxFolder()
        let word1 = Word(
            id: nil, lemma: "Run", phonetic: nil,
            definition: "v1", createdAt: Date(), updatedAt: Date(),
            reviewCount: 0, nextReviewAt: nil, familiarity: 0,
            folderId: inbox.id!
        )
        let word2 = Word(
            id: nil, lemma: "run", phonetic: nil,
            definition: "v2", createdAt: Date(), updatedAt: Date(),
            reviewCount: 0, nextReviewAt: nil, familiarity: 0,
            folderId: inbox.id!
        )

        _ = try await db.saveWord(word1)
        _ = try await db.saveWord(word2) // unique(onConflict: .ignore)

        let all = try await db.getAllWords()
        XCTAssertEqual(all.count, 1, "Duplicate lemma (case-insensitive) should be ignored")
    }

    func testGetWordByLemma() async throws {
        let inbox = try await db.getInboxFolder()
        let word = Word(
            id: nil, lemma: "ephemeral", phonetic: nil,
            definition: "短暂的\nephemeral",
            createdAt: Date(), updatedAt: Date(),
            reviewCount: 0, nextReviewAt: nil, familiarity: 0,
            folderId: inbox.id!
        )
        _ = try await db.saveWord(word)

        let fetched = try await db.getWord(lemma: "Ephemeral") // case-insensitive
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.lemma, "ephemeral")
    }

    // MARK: - WordSource CRUD

    func testSaveWordSourceAndCascadeDelete() async throws {
        let inbox = try await db.getInboxFolder()
        var word = Word(
            id: nil, lemma: "cascade", phonetic: nil,
            definition: "级联\ncascade",
            createdAt: Date(), updatedAt: Date(),
            reviewCount: 0, nextReviewAt: nil, familiarity: 0,
            folderId: inbox.id!
        )
        word = try await db.saveWord(word)

        let source = WordSource(
            id: nil, wordId: word.id!, captureJobId: nil,
            surfaceForm: "cascading", sentence: "The cascading waterfall.",
            sentenceTranslation: nil, wordInTranslation: nil,
            sentenceSource: "selected", sourceApp: "Safari",
            bundleId: "com.apple.Safari", sourceUrl: nil, sourceTitle: nil,
            sourceStatus: "resolved", aiModel: nil, aiLatencyMs: nil,
            needsReview: false, capturedAt: Date()
        )
        _ = try await db.saveWordSource(source)

        let sources = try await db.getSourcesForWord(wordId: word.id!)
        XCTAssertEqual(sources.count, 1)
    }

    // MARK: - Folder CRUD

    func testCreateFolder() async throws {
        let folder = try await db.createFolder(name: "  Favorites  ")
        XCTAssertEqual(folder.name, "Favorites") // trimmed
        XCTAssertFalse(folder.isSystem)
    }

    func testDeleteFolderMovesWordsToInbox() async throws {
        let inbox = try await db.getInboxFolder()
        let folder = try await db.createFolder(name: "Custom")

        // Save word in custom folder
        let word = Word(
            id: nil, lemma: "orphan", phonetic: nil,
            definition: "孤儿\norphan",
            createdAt: Date(), updatedAt: Date(),
            reviewCount: 0, nextReviewAt: nil, familiarity: 0,
            folderId: folder.id!
        )
        let saved = try await db.saveWord(word)

        // Delete the folder
        try await db.deleteFolder(folder)

        // Word should now be in Inbox
        let fetched = try await db.getWord(id: saved.id!)
        XCTAssertEqual(fetched?.folderId, inbox.id)
    }

    func testRenameFolder() async throws {
        let folder = try await db.createFolder(name: "Old Name")
        try await db.renameFolder(folder, to: "New Name")

        let all = try await db.getAllFolders()
        let renamed = all.first { $0.id == folder.id }
        XCTAssertEqual(renamed?.name, "New Name")
    }

    func testCannotDeleteSystemFolder() async throws {
        let inbox = try await db.getInboxFolder()
        try await db.deleteFolder(inbox) // should be a no-op

        let folders = try await db.getAllFolders()
        XCTAssertTrue(folders.contains { $0.isSystem })
    }

    func testMoveWords() async throws {
        let inbox = try await db.getInboxFolder()
        let folder = try await db.createFolder(name: "Target")

        let word = Word(
            id: nil, lemma: "moveme", phonetic: nil,
            definition: "test", createdAt: Date(), updatedAt: Date(),
            reviewCount: 0, nextReviewAt: nil, familiarity: 0,
            folderId: inbox.id!
        )
        let saved = try await db.saveWord(word)

        try await db.moveWords([saved.id!], toFolder: folder.id!)

        let fetched = try await db.getWord(id: saved.id!)
        XCTAssertEqual(fetched?.folderId, folder.id)
    }

    // MARK: - Delete Words

    func testDeleteWords() async throws {
        let inbox = try await db.getInboxFolder()
        let now = Date()
        let w1 = try await db.saveWord(Word(
            id: nil, lemma: "alpha", phonetic: nil, definition: "a",
            createdAt: now, updatedAt: now, reviewCount: 0, nextReviewAt: nil,
            familiarity: 0, folderId: inbox.id!
        ))
        let w2 = try await db.saveWord(Word(
            id: nil, lemma: "beta", phonetic: nil, definition: "b",
            createdAt: now, updatedAt: now, reviewCount: 0, nextReviewAt: nil,
            familiarity: 0, folderId: inbox.id!
        ))

        try await db.deleteWords(ids: Set([w1.id!, w2.id!]))

        let all = try await db.getAllWords()
        XCTAssertTrue(all.isEmpty)
    }

    func testDeleteWordCascadesWordSources() async throws {
        let inbox = try await db.getInboxFolder()
        let now = Date()
        let word = try await db.saveWord(Word(
            id: nil, lemma: "cascade", phonetic: nil, definition: "test",
            createdAt: now, updatedAt: now, reviewCount: 0, nextReviewAt: nil,
            familiarity: 0, folderId: inbox.id!
        ))
        _ = try await db.saveWordSource(WordSource(
            id: nil, wordId: word.id!, captureJobId: nil,
            surfaceForm: "cascading", sentence: "The cascading effect.",
            sentenceTranslation: nil, wordInTranslation: nil,
            sentenceSource: "selected", sourceApp: "Safari",
            bundleId: "com.apple.Safari", sourceUrl: nil, sourceTitle: nil,
            sourceStatus: "resolved", aiModel: nil, aiLatencyMs: nil,
            needsReview: false, capturedAt: now
        ))

        try await db.deleteWords(ids: Set([word.id!]))

        let sources = try await db.getSourcesForWord(wordId: word.id!)
        XCTAssertTrue(sources.isEmpty, "Word sources should cascade delete")
    }

    func testGetWordWithSources() async throws {
        let inbox = try await db.getInboxFolder()
        let now = Date()
        let word = try await db.saveWord(Word(
            id: nil, lemma: "snapshot", phonetic: "/ˈsnæpʃɒt/", definition: "快照\nsnapshot",
            createdAt: now, updatedAt: now, reviewCount: 0, nextReviewAt: nil,
            familiarity: 0, folderId: inbox.id!
        ))
        _ = try await db.saveWordSource(WordSource(
            id: nil, wordId: word.id!, captureJobId: nil,
            surfaceForm: "snapshot", sentence: "Take a snapshot.",
            sentenceTranslation: nil, wordInTranslation: nil,
            sentenceSource: "selected", sourceApp: "Safari",
            bundleId: "com.apple.Safari", sourceUrl: nil, sourceTitle: nil,
            sourceStatus: "resolved", aiModel: nil, aiLatencyMs: nil,
            needsReview: false, capturedAt: now
        ))

        let result = try await db.getWordWithSources(id: word.id!)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.0.lemma, "snapshot")
        XCTAssertEqual(result?.1.count, 1)
    }

    func testRestoreWord() async throws {
        let inbox = try await db.getInboxFolder()
        let now = Date()
        let word = try await db.saveWord(Word(
            id: nil, lemma: "restore", phonetic: nil, definition: "恢复\nto restore",
            createdAt: now, updatedAt: now, reviewCount: 0, nextReviewAt: nil,
            familiarity: 0, folderId: inbox.id!
        ))
        let source = try await db.saveWordSource(WordSource(
            id: nil, wordId: word.id!, captureJobId: nil,
            surfaceForm: "restored", sentence: "I restored the file.",
            sentenceTranslation: nil, wordInTranslation: nil,
            sentenceSource: "selected", sourceApp: "Safari",
            bundleId: "com.apple.Safari", sourceUrl: nil, sourceTitle: nil,
            sourceStatus: "resolved", aiModel: nil, aiLatencyMs: nil,
            needsReview: false, capturedAt: now
        ))

        // Delete
        try await db.deleteWords(ids: Set([word.id!]))
        let afterDelete = try await db.getWord(id: word.id!)
        XCTAssertNil(afterDelete)

        // Restore
        let restored = try await db.restoreWord(word, sources: [source])
        XCTAssertNotNil(restored.id)
        XCTAssertEqual(restored.lemma, "restore")

        let restoredSources = try await db.getSourcesForWord(wordId: restored.id!)
        XCTAssertEqual(restoredSources.count, 1)
        XCTAssertEqual(restoredSources.first?.surfaceForm, "restored")
    }

    func testRestoreWordMergesSourcesOnLemmaConflict() async throws {
        let inbox = try await db.getInboxFolder()
        let now = Date()

        // Create word with source, snapshot it, then delete
        let original = try await db.saveWord(Word(
            id: nil, lemma: "merge", phonetic: nil, definition: "合并\nto merge",
            createdAt: now, updatedAt: now, reviewCount: 0, nextReviewAt: nil,
            familiarity: 0, folderId: inbox.id!
        ))
        let oldSource = try await db.saveWordSource(WordSource(
            id: nil, wordId: original.id!, captureJobId: nil,
            surfaceForm: "merged", sentence: "We merged the branches.",
            sentenceTranslation: nil, wordInTranslation: nil,
            sentenceSource: "selected", sourceApp: "Safari",
            bundleId: "com.apple.Safari", sourceUrl: nil, sourceTitle: nil,
            sourceStatus: "resolved", aiModel: nil, aiLatencyMs: nil,
            needsReview: false, capturedAt: now
        ))

        try await db.deleteWords(ids: Set([original.id!]))

        // Re-create word with same lemma (simulates re-capture)
        let recaptured = try await db.saveWord(Word(
            id: nil, lemma: "merge", phonetic: nil, definition: "合并（新释义）\nto merge (new)",
            createdAt: now, updatedAt: now, reviewCount: 0, nextReviewAt: nil,
            familiarity: 0, folderId: inbox.id!
        ))
        _ = try await db.saveWordSource(WordSource(
            id: nil, wordId: recaptured.id!, captureJobId: nil,
            surfaceForm: "merging", sentence: "Merging is fun.",
            sentenceTranslation: nil, wordInTranslation: nil,
            sentenceSource: "selected", sourceApp: "Chrome",
            bundleId: "com.google.Chrome", sourceUrl: nil, sourceTitle: nil,
            sourceStatus: "resolved", aiModel: nil, aiLatencyMs: nil,
            needsReview: false, capturedAt: now
        ))

        // Undo: restore original word — should merge sources into existing
        let restored = try await db.restoreWord(original, sources: [oldSource])
        XCTAssertEqual(restored.id, recaptured.id, "Should merge into existing word")

        let allSources = try await db.getSourcesForWord(wordId: restored.id!)
        XCTAssertEqual(allSources.count, 2, "Should have both old and new sources")
    }
}
