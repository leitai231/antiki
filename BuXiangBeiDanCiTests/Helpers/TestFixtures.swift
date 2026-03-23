import Foundation
@testable import BuXiangBeiDanCi

/// Reusable test data factories
enum TestFixtures {

    static let defaultSource = CaptureSource(
        app: "Safari",
        bundleId: "com.apple.Safari",
        url: "https://example.com/article",
        title: "Test Article",
        status: .resolved
    )

    static func makeCaptureJob(
        selectedText: String = "running",
        sentence: String = "I was running in the park.",
        status: CaptureJob.JobStatus = .pending
    ) -> CaptureJob {
        CaptureJob(
            id: nil,
            selectedText: selectedText,
            normalizedText: selectedText.lowercased(),
            sentence: sentence,
            sourceApp: "Safari",
            bundleId: "com.apple.Safari",
            sourceUrl: "https://example.com",
            sourceTitle: "Test",
            sourceStatus: "resolved",
            captureMethod: "hotkey",
            status: status,
            needsReview: false,
            errorMessage: nil,
            errorCategory: nil,
            retryCount: 0,
            createdAt: Date(),
            processedAt: nil
        )
    }

    static func makeAIResponse(
        lemma: String = "run",
        surfaceForm: String = "running",
        definition: String = "跑步；奔跑\nto run; to jog"
    ) -> AIResponse {
        AIResponse(
            lemma: lemma,
            surfaceForm: surfaceForm,
            phonetic: "/rʌn/",
            definition: definition,
            sentence: "I was running in the park.",
            sentenceSource: .selected,
            sentenceTranslation: "我在公园里跑步。",
            wordInTranslation: "跑步",
            needsReview: false,
            confidenceNotes: nil
        )
    }

    static func makeAISuccess(
        lemma: String = "run",
        surfaceForm: String = "running",
        definition: String = "跑步；奔跑\nto run; to jog"
    ) -> AIProcessingSuccess {
        AIProcessingSuccess(
            response: makeAIResponse(lemma: lemma, surfaceForm: surfaceForm, definition: definition),
            model: "gpt-4o-mini",
            latencyMs: 150
        )
    }
}
