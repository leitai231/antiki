import Foundation
@testable import BuXiangBeiDanCi

/// A mock AI processor for testing capture flow without hitting OpenAI.
/// Configure `resultToReturn` or `errorToThrow` before each test.
actor MockAIProcessor: AIProcessing {

    var resultToReturn: AIProcessingSuccess?
    var errorToThrow: Error?
    private(set) var processCallCount = 0
    private(set) var lastJob: CaptureJob?

    func process(job: CaptureJob, existingDefinition: String?) async throws -> AIProcessingSuccess {
        processCallCount += 1
        lastJob = job

        if let error = errorToThrow {
            throw error
        }

        guard let result = resultToReturn else {
            fatalError("MockAIProcessor: set resultToReturn or errorToThrow before calling process()")
        }

        return result
    }

    func reset() {
        resultToReturn = nil
        errorToThrow = nil
        processCallCount = 0
        lastJob = nil
    }
}
