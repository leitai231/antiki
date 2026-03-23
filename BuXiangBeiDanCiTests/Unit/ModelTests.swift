import XCTest
@testable import BuXiangBeiDanCi

final class ModelTests: XCTestCase {

    // MARK: - Word computed properties

    func testWordIsProcessing() {
        let word = makeWord(definition: "⏳")
        XCTAssertTrue(word.isProcessing)
    }

    func testWordIsNotProcessing() {
        let word = makeWord(definition: "to run")
        XCTAssertFalse(word.isProcessing)
    }

    func testWordIsFailed() {
        let word = makeWord(definition: "❌ 获取失败")
        XCTAssertTrue(word.isFailed)
    }

    func testWordIsNotFailed() {
        let word = makeWord(definition: "to run")
        XCTAssertFalse(word.isFailed)
    }

    // MARK: - CaptureJob.JobStatus

    func testJobStatusRawValues() {
        XCTAssertEqual(CaptureJob.JobStatus.pending.rawValue, "pending")
        XCTAssertEqual(CaptureJob.JobStatus.processing.rawValue, "processing")
        XCTAssertEqual(CaptureJob.JobStatus.completed.rawValue, "completed")
        XCTAssertEqual(CaptureJob.JobStatus.failed.rawValue, "failed")
    }

    // MARK: - AIResponse JSON decoding

    func testAIResponseDecoding() throws {
        let json = """
        {
            "lemma": "run",
            "surface_form": "running",
            "phonetic": "/rʌn/",
            "definition": "跑步\\nto run",
            "sentence": "I was running.",
            "sentence_translation": "我在跑步。",
            "word_in_translation": "跑步",
            "needs_review": false
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(AIResponse.self, from: data)
        XCTAssertEqual(response.lemma, "run")
        XCTAssertEqual(response.surfaceForm, "running")
        XCTAssertEqual(response.phonetic, "/rʌn/")
        XCTAssertFalse(response.needsReview)
    }

    func testAIResponseDecodingWithNullOptionals() throws {
        let json = """
        {
            "lemma": "test",
            "surface_form": "test",
            "definition": "测试\\nto test",
            "needs_review": true
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(AIResponse.self, from: data)
        XCTAssertNil(response.phonetic)
        XCTAssertNil(response.sentenceTranslation)
        XCTAssertTrue(response.needsReview)
    }

    // MARK: - Helpers

    private func makeWord(definition: String) -> Word {
        Word(
            id: 1,
            lemma: "test",
            phonetic: nil,
            definition: definition,
            createdAt: Date(),
            updatedAt: Date(),
            reviewCount: 0,
            nextReviewAt: nil,
            familiarity: 0,
            folderId: 1
        )
    }
}
