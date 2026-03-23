import XCTest
@testable import BuXiangBeiDanCi

@MainActor
final class CaptureFlowTests: XCTestCase {

    private var db: AppDatabase!
    private var mockAI: MockAIProcessor!
    private var coordinator: CaptureCoordinator!

    override func setUpWithError() throws {
        db = try TestDatabase.make()
        mockAI = MockAIProcessor()
        coordinator = CaptureCoordinator(database: db, ai: mockAI)
    }

    // MARK: - Capture creates job + placeholder

    func testCaptureCreatesJobAndPlaceholder() async throws {
        // Configure mock to return success
        await mockAI.setResult(TestFixtures.makeAISuccess())

        await coordinator.capture(
            word: "running",
            sentence: "I was running in the park.",
            source: TestFixtures.defaultSource
        )

        // Wait briefly for async AI processing
        try await Task.sleep(for: .milliseconds(200))

        // Job should exist
        let jobs = try await db.getRecentCaptureJobs(limit: 10)
        XCTAssertFalse(jobs.isEmpty)

        // Word should exist (not placeholder since AI succeeded)
        let word = try await db.getWord(lemma: "run")
        XCTAssertNotNil(word)
    }

    func testCaptureEmptyWordIsSkipped() async throws {
        await coordinator.capture(
            word: "   ",
            sentence: "test",
            source: TestFixtures.defaultSource
        )

        let jobs = try await db.getRecentCaptureJobs(limit: 10)
        XCTAssertTrue(jobs.isEmpty)
    }

    // MARK: - AI success flow

    func testAISuccessUpdatesWordDefinition() async throws {
        let aiSuccess = TestFixtures.makeAISuccess(
            definition: "跑步；奔跑\nto run; to jog"
        )
        await setMockResult(aiSuccess)

        await coordinator.capture(
            word: "running",
            sentence: "I was running in the park.",
            source: TestFixtures.defaultSource
        )

        try await Task.sleep(for: .milliseconds(300))

        let word = try await db.getWord(lemma: "run")
        XCTAssertNotNil(word)
        XCTAssertNotEqual(word?.definition, "⏳", "Placeholder should be replaced")
        XCTAssertTrue(word?.definition.contains("跑步") ?? false)
    }

    func testAISuccessCreatesWordSource() async throws {
        await setMockResult(TestFixtures.makeAISuccess())

        await coordinator.capture(
            word: "running",
            sentence: "I was running in the park.",
            source: TestFixtures.defaultSource
        )

        try await Task.sleep(for: .milliseconds(300))

        let word = try await db.getWord(lemma: "run")
        XCTAssertNotNil(word)

        if let wordId = word?.id {
            let sources = try await db.getSourcesForWord(wordId: wordId)
            XCTAssertEqual(sources.count, 1)
            XCTAssertEqual(sources.first?.surfaceForm, "running")
        }
    }

    func testAISuccessRemovesPlaceholderWhenFinalLemmaDiffers() async throws {
        await setMockResult(TestFixtures.makeAISuccess(lemma: "run", surfaceForm: "running"))

        await coordinator.capture(
            word: "running",
            sentence: "I was running in the park.",
            source: TestFixtures.defaultSource
        )

        try await Task.sleep(for: .milliseconds(300))

        let allWords = try await db.getAllWords()
        XCTAssertEqual(allWords.filter { $0.lemma == "run" }.count, 1)
        XCTAssertFalse(allWords.contains { $0.lemma == "running" })
    }

    func testAISuccessDoesNotLeaveLegacyTokenizerPlaceholderBehind() async throws {
        await setMockResult(TestFixtures.makeAISuccess(
            lemma: "lucid",
            surfaceForm: "lucid",
            definition: "清醒的；明晰的\nclear-headed; able to think clearly"
        ))

        await coordinator.capture(
            word: "lucid",
            sentence: "The explanation was lucid.",
            source: TestFixtures.defaultSource
        )

        try await Task.sleep(for: .milliseconds(300))

        let allWords = try await db.getAllWords()
        XCTAssertEqual(allWords.filter { $0.lemma == "lucid" }.count, 1)
        XCTAssertFalse(allWords.contains { $0.lemma == "lucir" })
    }

    func testLoadAllWordsRemovesStaleOrphanPlaceholder() async throws {
        let inboxId = try await db.getInboxFolder().id ?? 1
        let now = Date()
        _ = try await db.saveWord(
            Word(
                id: nil,
                lemma: "strand",
                phonetic: nil,
                definition: "⏳",
                createdAt: now,
                updatedAt: now,
                reviewCount: 0,
                nextReviewAt: nil,
                familiarity: 0,
                folderId: inboxId
            )
        )

        await coordinator.loadAllWords()

        let allWords = try await db.getAllWords()
        XCTAssertFalse(allWords.contains { $0.lemma == "strand" })
    }

    // MARK: - AI failure flow

    func testAIFailureMarksJobFailed() async throws {
        await setMockError(AIProcessingError.missingAPIKey)

        await coordinator.capture(
            word: "failing",
            sentence: "This will fail.",
            source: TestFixtures.defaultSource
        )

        try await Task.sleep(for: .milliseconds(300))

        let jobs = try await db.getRecentCaptureJobs(limit: 10)
        let failedJobs = jobs.filter { $0.status == .failed }
        XCTAssertFalse(failedJobs.isEmpty)
    }

    // MARK: - Deduplication

    func testSameWordTwiceDoesNotDuplicateWord() async throws {
        await setMockResult(TestFixtures.makeAISuccess())

        await coordinator.capture(
            word: "running",
            sentence: "I was running in the park.",
            source: TestFixtures.defaultSource
        )
        try await Task.sleep(for: .milliseconds(300))

        await coordinator.capture(
            word: "runs",
            sentence: "She runs every day.",
            source: TestFixtures.defaultSource
        )
        try await Task.sleep(for: .milliseconds(300))

        // Both "running" and "runs" lemmatize to "run" — should be one word
        let allWords = try await db.getAllWords()
        let runWords = allWords.filter { $0.lemma == "run" }
        XCTAssertEqual(runWords.count, 1, "Same lemma should not create duplicate words")
    }

    // MARK: - Delete & Undo

    func testDeleteWordRemovesFromList() async throws {
        await setMockResult(TestFixtures.makeAISuccess())

        await coordinator.capture(
            word: "running",
            sentence: "I was running in the park.",
            source: TestFixtures.defaultSource
        )
        try await Task.sleep(for: .milliseconds(300))

        let word = try await db.getWord(lemma: "run")
        XCTAssertNotNil(word)

        await coordinator.deleteWords(Set([word!.id!]))

        let allWords = try await db.getAllWords()
        XCTAssertFalse(allWords.contains { $0.lemma == "run" })
        XCTAssertTrue(coordinator.canUndo)
    }

    func testUndoRestoresDeletedWord() async throws {
        await setMockResult(TestFixtures.makeAISuccess())

        await coordinator.capture(
            word: "running",
            sentence: "I was running in the park.",
            source: TestFixtures.defaultSource
        )
        try await Task.sleep(for: .milliseconds(300))

        let word = try await db.getWord(lemma: "run")
        XCTAssertNotNil(word)

        await coordinator.deleteWords(Set([word!.id!]))
        XCTAssertTrue(coordinator.canUndo)

        await coordinator.undoLastDelete()

        let restored = try await db.getWord(lemma: "run")
        XCTAssertNotNil(restored, "Word should be restored after undo")
        XCTAssertFalse(coordinator.canUndo)

        let sources = try await db.getSourcesForWord(wordId: restored!.id!)
        XCTAssertEqual(sources.count, 1, "Sources should be restored")
    }

    func testDeleteDoesNotRemoveCaptureJobs() async throws {
        await setMockResult(TestFixtures.makeAISuccess())

        await coordinator.capture(
            word: "running",
            sentence: "I was running in the park.",
            source: TestFixtures.defaultSource
        )
        try await Task.sleep(for: .milliseconds(300))

        let jobsBefore = try await db.getRecentCaptureJobs(limit: 10)
        XCTAssertFalse(jobsBefore.isEmpty)

        let word = try await db.getWord(lemma: "run")
        await coordinator.deleteWords(Set([word!.id!]))

        let jobsAfter = try await db.getRecentCaptureJobs(limit: 10)
        XCTAssertEqual(jobsAfter.count, jobsBefore.count,
                       "Capture jobs should not be deleted when word is deleted")
    }

    func testBatchDelete() async throws {
        await setMockResult(TestFixtures.makeAISuccess(lemma: "run", surfaceForm: "running"))

        await coordinator.capture(
            word: "running",
            sentence: "I was running.",
            source: TestFixtures.defaultSource
        )
        try await Task.sleep(for: .milliseconds(300))

        await setMockResult(TestFixtures.makeAISuccess(lemma: "jump", surfaceForm: "jumping", definition: "跳\nto jump"))

        await coordinator.capture(
            word: "jumping",
            sentence: "She was jumping.",
            source: TestFixtures.defaultSource
        )
        try await Task.sleep(for: .milliseconds(300))

        let allWords = try await db.getAllWords()
        let ids = Set(allWords.compactMap(\.id))
        XCTAssertEqual(ids.count, 2)

        await coordinator.deleteWords(ids)

        let remaining = try await db.getAllWords()
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Helpers

    private func setMockResult(_ result: AIProcessingSuccess) async {
        // Direct property set on the actor
        await mockAI.setResult(result)
    }

    private func setMockError(_ error: Error) async {
        await mockAI.setError(error)
    }
}

// Actor extension for cleaner test setup
extension MockAIProcessor {
    func setResult(_ result: AIProcessingSuccess) {
        self.resultToReturn = result
        self.errorToThrow = nil
    }

    func setError(_ error: Error) {
        self.errorToThrow = error
        self.resultToReturn = nil
    }
}
