import Foundation
import os.log

/// Coordinates the capture workflow
/// Responsible for: storing to DB → triggering AI processing
@MainActor
class CaptureCoordinator: ObservableObject {
    
    static let shared = CaptureCoordinator()

    private let logger = Logger(subsystem: "com.blackkingbar.buxiangbeidanci", category: "capture")
    private let db: Database
    private let aiProcessor: any AIProcessing
    private var deleteSnapshots: [WordSnapshot] = []

    /// Published list of recent captures for UI
    @Published var recentCaptures: [CaptureJob] = []
    
    /// Published word list for vocabulary view
    @Published var allWords: [Word] = []

    /// Published folder list for sidebar
    @Published var folders: [Folder] = []

    /// Folder word counts derived from allWords (single source of truth)
    var folderWordCounts: [Int64: Int] {
        Dictionary(grouping: allWords, by: \.folderId).mapValues(\.count)
    }

    /// Published counts for UI
    @Published var pendingCount: Int = 0
    @Published var processingCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var needsReviewCount: Int = 0

    /// Incremented after each word processing to trigger detail view refresh
    @Published var wordChangeCounter: Int = 0

    /// Toast notification state
    @Published var toastMessage: String?
    /// Whether undo is available for the last delete action
    @Published var canUndo: Bool = false
    /// AI success rate metrics (all-time from DB)
    @Published var totalCompleted: Int = 0
    @Published var totalFailed: Int = 0
    
    private init() {
        self.db = Database.shared
        self.aiProcessor = AIProcessor.shared
        Task {
            await loadRecentCaptures()
        }
    }

    /// Internal init for testing with injected dependencies
    init(database: Database, ai: any AIProcessing) {
        self.db = database
        self.aiProcessor = ai
    }
    
    /// Main entry point for capturing a word with its sentence context
    func capture(word: String, sentence: String, source: CaptureSource) async {
        logger.info("🎯 Capturing word: \(word)")
        
        // 1. Normalize input
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !normalizedWord.isEmpty else {
            logger.warning("⚠️ Empty word, skipping")
            return
        }
        
        // 2. Create capture job
        let job = CaptureJob(
            id: nil,
            selectedText: word,
            normalizedText: normalizedWord,
            sentence: normalizedSentence,
            sourceApp: source.app,
            bundleId: source.bundleId,
            sourceUrl: source.url,
            sourceTitle: source.title,
            sourceStatus: source.status.rawValue,
            captureMethod: "hotkey",
            status: .pending,
            needsReview: false,
            errorMessage: nil,
            errorCategory: nil,
            retryCount: 0,
            createdAt: Date(),
            processedAt: nil
        )
        
        // 3. Save to database (pending status)
        do {
            let savedJob = try await db.saveCaptureJob(job)
            logger.info("✅ Capture job saved with id: \(savedJob.id ?? -1)")
            
            // Update UI
            recentCaptures.insert(savedJob, at: 0)
            refreshCaptureStats()
            
            // 4. Phase 1: insert placeholder word so it appears immediately
            try await upsertPlaceholderWord(lemma: normalizedWord)
            await loadAllWords()

            // 5. Trigger async AI processing (Phase 2)
            Task {
                await processJob(savedJob)
            }
            
        } catch {
            logger.error("❌ Failed to save capture job: \(error)")
        }
    }
    
    /// Process a capture job (AI processing)
    private func processJob(_ job: CaptureJob) async {
        logger.info("🔄 Processing job \(job.id ?? -1)...")
        
        // Update status to processing
        var updatedJob = job
        updatedJob.status = .processing
        
        do {
            try await db.updateCaptureJob(updatedJob)
            
            // Update UI
            if let index = recentCaptures.firstIndex(where: { $0.id == job.id }) {
                recentCaptures[index] = updatedJob
            }
            refreshCaptureStats()
            
            // Look up existing word to pass current definition for merging
            let existingWord = try? await db.getWord(lemma: updatedJob.normalizedText)
            let existingDefinition = existingWord?.isProcessing == true ? nil : existingWord?.definition

            // Real AI processing + persistence
            let aiResult = try await aiProcessor.process(job: updatedJob, existingDefinition: existingDefinition)
            try await persistAIResult(aiResult, for: updatedJob)
            
            // Mark as completed
            updatedJob.status = .completed
            updatedJob.needsReview = aiResult.response.needsReview
            updatedJob.processedAt = Date()
            try await db.updateCaptureJob(updatedJob)
            
            logger.info("✅ Job \(job.id ?? -1) completed")

            // Update the job in recentCaptures
            if let index = recentCaptures.firstIndex(where: { $0.id == job.id }) {
                recentCaptures[index] = updatedJob
            }
            refreshCaptureStats()

            // Refresh word list and notify detail views
            await loadAllWords()
            wordChangeCounter += 1
            
        } catch let error as AIProcessingError {
            logger.error("❌ AI processing failed: \(error.localizedDescription)")
            await markJobAsFailed(
                job: updatedJob,
                message: error.localizedDescription,
                category: error.category
            )
        } catch {
            logger.error("❌ Failed to process job: \(error)")

            await markJobAsFailed(
                job: updatedJob,
                message: error.localizedDescription,
                category: "processing"
            )
        }
    }

    private func markJobAsFailed(job: CaptureJob, message: String, category: String) async {
        var failedJob = job
        failedJob.status = .failed
        failedJob.errorMessage = message
        failedJob.errorCategory = category

        try? await db.updateCaptureJob(failedJob)

        if let index = recentCaptures.firstIndex(where: { $0.id == failedJob.id }) {
            recentCaptures[index] = failedJob
        }
        refreshCaptureStats()

        // Update placeholder word to show failure state
        let lemma = failedJob.normalizedText
        if var word = try? await db.getWord(lemma: lemma), word.isProcessing {
            word.definition = "❌ 获取失败"
            word.updatedAt = Date()
            try? await db.updateWord(word)
            await loadAllWords()
            wordChangeCounter += 1
        }
    }

    /// Insert a placeholder word so the UI shows it immediately while AI processes.
    /// If the word already exists, bump its updatedAt so it floats to the top of the list.
    private func upsertPlaceholderWord(lemma: String) async throws {
        let normalizedLemma = lemma.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedLemma.isEmpty else { return }

        if var existing = try? await db.getWord(lemma: normalizedLemma) {
            existing.updatedAt = Date()
            try? await db.updateWord(existing)
            return
        }

        let inboxId = (try? await db.getInboxFolder().id) ?? 1
        let now = Date()
        let placeholder = Word(
            id: nil,
            lemma: normalizedLemma,
            phonetic: nil,
            definition: "⏳",
            createdAt: now,
            updatedAt: now,
            reviewCount: 0,
            nextReviewAt: nil,
            familiarity: 0,
            folderId: inboxId
        )

        _ = try await db.saveWord(placeholder)
    }

    private func persistAIResult(_ result: AIProcessingSuccess, for job: CaptureJob) async throws {
        // Inherit folder from placeholder (user may have moved it before AI finished)
        let placeholder = try? await db.getWord(lemma: job.normalizedText)
        let inheritedFolderId = placeholder?.folderId

        // When AI returns a different lemma (e.g. "running" → "run"), rename the
        // placeholder in-place so its word ID is preserved. This keeps any active
        // UI selection valid after the refresh.
        let aiLemma = result.response.lemma
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let jobLemma = job.normalizedText
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if var placeholder, placeholder.isProcessing,
           aiLemma != jobLemma {
            let targetExists = (try? await db.getWord(lemma: aiLemma)) != nil
            if !targetExists {
                placeholder.lemma = aiLemma
                try? await db.updateWord(placeholder)
            } else if let placeholderId = placeholder.id {
                try? await db.deleteWord(id: placeholderId)
            }
        }

        let word = try await upsertWord(
            lemma: result.response.lemma,
            phonetic: normalizedOptional(result.response.phonetic),
            definition: result.response.definition,
            inheritedFolderId: inheritedFolderId
        )

        guard let wordId = word.id else {
            throw AIProcessingError.databaseInconsistent("Word id is missing after upsert")
        }

        let source = WordSource(
            id: nil,
            wordId: wordId,
            captureJobId: job.id,
            surfaceForm: result.response.surfaceForm,
            sentence: job.sentence ?? job.selectedText,
            sentenceTranslation: normalizedOptional(result.response.sentenceTranslation),
            wordInTranslation: normalizedOptional(result.response.wordInTranslation),
            sentenceSource: "selected",
            sourceApp: job.sourceApp,
            bundleId: job.bundleId,
            sourceUrl: job.sourceUrl,
            sourceTitle: job.sourceTitle,
            sourceStatus: job.sourceStatus,
            aiModel: result.model,
            aiLatencyMs: result.latencyMs,
            needsReview: result.response.needsReview,
            capturedAt: Date()
        )

        _ = try await db.saveWordSource(source)
    }

    private func upsertWord(lemma: String, phonetic: String?, definition: String, inheritedFolderId: Int64? = nil) async throws -> Word {
        let normalizedLemma = lemma.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedLemma.isEmpty else {
            throw AIProcessingError.schemaValidationFailed(field: "lemma", reason: "empty")
        }

        if var existing = try await db.getWord(lemma: normalizedLemma) {
            existing.updatedAt = Date()
            existing.definition = definition

            if (existing.phonetic?.isEmpty ?? true), let phonetic {
                existing.phonetic = phonetic
            }

            // Do NOT touch existing.folderId — preserve user's folder assignment
            try await db.updateWord(existing)
            return existing
        }

        let inboxId = (try? await db.getInboxFolder().id) ?? 1
        let folderId = inheritedFolderId ?? inboxId

        let now = Date()
        let candidate = Word(
            id: nil,
            lemma: normalizedLemma,
            phonetic: phonetic,
            definition: definition,
            createdAt: now,
            updatedAt: now,
            reviewCount: 0,
            nextReviewAt: nil,
            familiarity: 0,
            folderId: folderId
        )

        let saved = try await db.saveWord(candidate)
        if saved.id != nil {
            return saved
        }

        // unique-on-conflict ignore can return without id; fetch the existing row.
        if let existing = try await db.getWord(lemma: normalizedLemma) {
            return existing
        }

        throw AIProcessingError.databaseInconsistent("Failed to resolve saved word for lemma: \(normalizedLemma)")
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "**", with: "")
        return trimmed.isEmpty ? nil : trimmed
    }
    
    /// Load recent captures from database
    func loadRecentCaptures() async {
        do {
            recentCaptures = try await db.getRecentCaptureJobs(limit: 50)
            refreshCaptureStats()
        } catch {
            logger.error("❌ Failed to load recent captures: \(error)")
        }
    }

    /// Load all words for vocabulary view
    func loadAllWords() async {
        do {
            try await cleanupOrphanedPlaceholders()
            allWords = try await db.getAllWords()
        } catch {
            logger.error("❌ Failed to load words: \(error)")
        }
    }

    /// Load all folders for sidebar
    func loadFolders() async {
        do {
            folders = try await db.getAllFolders()
        } catch {
            logger.error("❌ Failed to load folders: \(error)")
        }
    }

    func createFolder(name: String) async {
        do {
            _ = try await db.createFolder(name: name)
            await loadFolders()
        } catch {
            logger.error("❌ Failed to create folder: \(error)")
        }
    }

    func deleteFolder(_ folder: Folder) async {
        do {
            try await db.deleteFolder(folder)
            await loadFolders()
            await loadAllWords()
        } catch {
            logger.error("❌ Failed to delete folder: \(error)")
        }
    }

    func renameFolder(_ folder: Folder, to newName: String) async {
        do {
            try await db.renameFolder(folder, to: newName)
            await loadFolders()
        } catch {
            logger.error("❌ Failed to rename folder: \(error)")
        }
    }

    func moveWords(_ wordIds: Set<Int64>, toFolder folder: Folder) async {
        guard let folderId = folder.id else { return }
        do {
            try await db.moveWords(wordIds, toFolder: folderId)
            await loadAllWords()
        } catch {
            logger.error("❌ Failed to move words: \(error)")
        }
    }

    // MARK: - Delete Words

    func deleteWords(_ wordIds: Set<Int64>) async {
        guard !wordIds.isEmpty else { return }
        do {
            var snapshots: [WordSnapshot] = []
            for id in wordIds {
                if let (word, sources) = try await db.getWordWithSources(id: id) {
                    snapshots.append(WordSnapshot(word: word, sources: sources))
                }
            }
            guard !snapshots.isEmpty else { return }

            deleteSnapshots = snapshots
            try await db.deleteWords(ids: wordIds)
            await loadAllWords()

            if snapshots.count == 1, let lemma = snapshots.first?.word.lemma {
                showToast("已删除「\(lemma)」", withUndo: true)
            } else {
                showToast("已删除 \(snapshots.count) 个单词", withUndo: true)
            }
        } catch {
            logger.error("❌ Failed to delete words: \(error)")
            showToast("删除失败")
        }
    }

    func undoLastDelete() async {
        let snapshots = deleteSnapshots
        guard !snapshots.isEmpty else { return }
        deleteSnapshots = []
        canUndo = false
        toastMessage = nil

        do {
            for snapshot in snapshots {
                _ = try await db.restoreWord(snapshot.word, sources: snapshot.sources)
            }
            await loadAllWords()

            if snapshots.count == 1, let lemma = snapshots.first?.word.lemma {
                showToast("已恢复「\(lemma)」")
            } else {
                showToast("已恢复 \(snapshots.count) 个单词")
            }
        } catch {
            logger.error("❌ Failed to undo delete: \(error)")
            showToast("恢复失败")
        }
    }

    /// Get word associated with a capture job (for navigation)
    func wordForJob(_ job: CaptureJob) async -> Word? {
        guard let jobId = job.id, job.status == .completed else { return nil }
        return try? await db.getWordForCaptureJob(jobId: jobId)
    }
    
    /// Reprocess a word source that has bad/error content.
    /// Creates a new CaptureJob from source metadata, processes it,
    /// and removes the old bad source on success.
    func reprocessSource(_ source: WordSource) async {
        let job = CaptureJob(
            id: nil,
            selectedText: source.surfaceForm,
            normalizedText: source.surfaceForm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            sentence: nil,
            sourceApp: source.sourceApp,
            bundleId: source.bundleId,
            sourceUrl: source.sourceUrl,
            sourceTitle: source.sourceTitle,
            sourceStatus: source.sourceStatus,
            captureMethod: "reprocess",
            status: .pending,
            needsReview: false,
            errorMessage: nil,
            errorCategory: nil,
            retryCount: 0,
            createdAt: Date(),
            processedAt: nil
        )

        do {
            let savedJob = try await db.saveCaptureJob(job)
            showToast("正在重新获取「\(source.surfaceForm)」")
            await processJob(savedJob)

            // On success, delete the old bad source
            if let sourceId = source.id {
                try? await db.deleteWordSource(id: sourceId)
            }
        } catch {
            logger.error("❌ Failed to reprocess source: \(error)")
            showToast("重新获取失败，请稍后再试")
        }
    }

    /// Retry a failed job
    func retryJob(_ job: CaptureJob) async {
        guard job.status == .failed else { return }

        var updatedJob = job
        updatedJob.status = .pending
        updatedJob.needsReview = false
        updatedJob.retryCount += 1
        updatedJob.errorMessage = nil
        updatedJob.errorCategory = nil

        do {
            try await db.updateCaptureJob(updatedJob)

            if let index = recentCaptures.firstIndex(where: { $0.id == job.id }) {
                recentCaptures[index] = updatedJob
            }
            refreshCaptureStats()
            showToast("正在重试「\(job.selectedText)」（第 \(updatedJob.retryCount) 次）")

            // Reprocess
            Task {
                await processJob(updatedJob)
            }
        } catch {
            logger.error("❌ Failed to retry job: \(error)")
            showToast("重试失败：\(error.localizedDescription)")
        }
    }

    /// Show a toast message that auto-dismisses
    func showToast(_ message: String, withUndo: Bool = false) {
        toastMessage = message
        canUndo = withUndo
        if !withUndo {
            deleteSnapshots = []
        }
        let duration: TimeInterval = withUndo ? 5.0 : 2.5
        Task {
            try? await Task.sleep(for: .seconds(duration))
            if toastMessage == message {
                toastMessage = nil
                canUndo = false
                deleteSnapshots = []
            }
        }
    }

    /// Confirm a job has been reviewed, clearing the needsReview flag
    func confirmReview(job: CaptureJob) async {
        var updatedJob = job
        updatedJob.needsReview = false

        do {
            try await db.updateCaptureJob(updatedJob)

            // Also clear needsReview on the associated WordSource
            if let jobId = job.id,
               var source = try await db.getWordSourceForJob(captureJobId: jobId) {
                source.needsReview = false
                try await db.updateWordSource(source)
            }

            if let index = recentCaptures.firstIndex(where: { $0.id == job.id }) {
                recentCaptures[index] = updatedJob
            }
            refreshCaptureStats()
        } catch {
            logger.error("❌ Failed to confirm review: \(error)")
        }
    }

    /// Save edited review content (definition, phonetic, sentenceTranslation) and mark as reviewed
    func saveReviewEdits(
        job: CaptureJob,
        definition: String,
        phonetic: String?,
        sentenceTranslation: String?
    ) async {
        do {
            // Update the Word record via WordSource.wordId
            if let jobId = job.id,
               let source = try await db.getWordSourceForJob(captureJobId: jobId),
               var word = try await db.getWord(id: source.wordId) {
                word.definition = definition
                word.phonetic = phonetic
                word.updatedAt = Date()
                try await db.updateWord(word)
            }

            // Update the WordSource sentenceTranslation and clear needsReview
            if let jobId = job.id,
               var source = try await db.getWordSourceForJob(captureJobId: jobId) {
                source.sentenceTranslation = sentenceTranslation
                source.needsReview = false
                try await db.updateWordSource(source)
            }

            // Clear needsReview on the job
            var updatedJob = job
            updatedJob.needsReview = false
            try await db.updateCaptureJob(updatedJob)

            if let index = recentCaptures.firstIndex(where: { $0.id == job.id }) {
                recentCaptures[index] = updatedJob
            }
            refreshCaptureStats()
        } catch {
            logger.error("❌ Failed to save review edits: \(error)")
        }
    }

    private func refreshCaptureStats() {
        pendingCount = recentCaptures.filter { $0.status == .pending }.count
        processingCount = recentCaptures.filter { $0.status == .processing }.count
        failedCount = recentCaptures.filter { $0.status == .failed }.count
        needsReviewCount = recentCaptures.filter { $0.status == .completed && $0.needsReview }.count

        Task {
            await refreshAllTimeStats()
        }
    }

    private func refreshAllTimeStats() async {
        do {
            let counts = try await db.getJobStatusCounts()
            totalCompleted = counts[CaptureJob.JobStatus.completed.rawValue] ?? 0
            totalFailed = counts[CaptureJob.JobStatus.failed.rawValue] ?? 0
        } catch {
            logger.error("❌ Failed to load job status counts: \(error)")
        }
    }

    /// Computed success rate (0.0–1.0), nil if no processed jobs
    var successRate: Double? {
        let total = totalCompleted + totalFailed
        guard total > 0 else { return nil }
        return Double(totalCompleted) / Double(total)
    }

    private func cleanupOrphanedPlaceholders() async throws {
        let placeholderWords = try await db.getAllWords().filter(\.isProcessing)
        guard !placeholderWords.isEmpty else { return }

        let activeJobs = try await db.getActiveJobs()
        let activePlaceholderLemmas = Set(
            activeJobs.flatMap { placeholderCandidateLemmas(for: $0.normalizedText) }
        )

        for word in placeholderWords {
            let lemma = word.lemma.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !activePlaceholderLemmas.contains(lemma) else { continue }
            guard let wordId = word.id else { continue }

            let sources = try await db.getSourcesForWord(wordId: wordId)
            guard sources.isEmpty else { continue }

            try await db.deleteWord(id: wordId)
            logger.info("🧹 Removed stale placeholder word: \(lemma)")
        }
    }

    private func placeholderCandidateLemmas(for normalizedText: String) -> [String] {
        let normalized = normalizedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return [] }

        let legacyLemma = Tokenizer.lemmatize(normalized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if legacyLemma.isEmpty || legacyLemma == normalized {
            return [normalized]
        }

        return [normalized, legacyLemma]
    }
}

struct AIProcessingSuccess: Sendable {
    let response: AIResponse
    let model: String
    let latencyMs: Int
}

struct WordSnapshot {
    let word: Word
    let sources: [WordSource]
}

/// Protocol for AI processing — enables mocking in tests
protocol AIProcessing: Sendable {
    func process(job: CaptureJob, existingDefinition: String?) async throws -> AIProcessingSuccess
}

enum AIProcessingError: Error, LocalizedError {
    case missingAPIKey
    case network(underlying: Error)
    case rateLimited(retryAfter: TimeInterval?, apiMessage: String? = nil)
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse(raw: String)
    case schemaValidationFailed(field: String, reason: String)
    case databaseInconsistent(String)

    var category: String {
        switch self {
        case .missingAPIKey:
            return "config"
        case .network:
            return "network"
        case .rateLimited:
            return "rate_limit"
        case .requestFailed:
            return "api"
        case .invalidResponse, .schemaValidationFailed:
            return "schema"
        case .databaseInconsistent:
            return "database"
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未配置 OpenAI API Key，请在设置中填写。"
        case let .network(underlying):
            return "网络请求失败：\(underlying.localizedDescription)"
        case let .rateLimited(retryAfter, apiMessage):
            if let apiMessage, apiMessage.lowercased().contains("quota") {
                return "OpenAI 账户额度已用完，请充值后重试。(\(apiMessage))"
            }
            if let retryAfter {
                return "请求过于频繁，请在 \(Int(retryAfter)) 秒后重试。"
            }
            if let apiMessage {
                return "请求被限制：\(apiMessage)"
            }
            return "请求过于频繁，请稍后重试。"
        case let .requestFailed(statusCode, message):
            return "OpenAI 请求失败（\(statusCode)）：\(message)"
        case .invalidResponse:
            return "AI 返回格式无法解析，请重试。"
        case let .schemaValidationFailed(field, reason):
            return "AI 返回数据校验失败（\(field): \(reason)）。"
        case let .databaseInconsistent(message):
            return "数据库状态异常：\(message)"
        }
    }
}

struct AIResponse: Codable, Sendable {
    enum SentenceSource: String, Codable, Sendable {
        case selected
        case extracted
        case reconstructed
    }

    var lemma: String
    var surfaceForm: String
    var phonetic: String?
    var definition: String
    var sentence: String?
    var sentenceSource: SentenceSource?
    var sentenceTranslation: String?
    var wordInTranslation: String?
    var needsReview: Bool
    var confidenceNotes: String?

    enum CodingKeys: String, CodingKey {
        case lemma
        case surfaceForm = "surface_form"
        case phonetic
        case definition
        case sentence
        case sentenceSource = "sentence_source"
        case sentenceTranslation = "sentence_translation"
        case wordInTranslation = "word_in_translation"
        case needsReview = "needs_review"
        case confidenceNotes = "confidence_notes"
    }
}

actor AIProcessor: AIProcessing {
    static let shared = AIProcessor()

    private let logger = Logger(subsystem: "com.blackkingbar.buxiangbeidanci", category: "ai")
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    private init() {}

    func process(job: CaptureJob, existingDefinition: String? = nil) async throws -> AIProcessingSuccess {
        let apiKey = try resolvedAPIKey()
        let model = resolvedModel()
        let start = Date()

        let requestBody = buildRequestBody(job: job, model: model, existingDefinition: existingDefinition)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            throw AIProcessingError.invalidResponse(raw: "Failed to encode request: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AIProcessingError.network(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProcessingError.invalidResponse(raw: "Non-HTTP response")
        }

        if httpResponse.statusCode == 429 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let body = decodeErrorMessage(from: data)
            logger.error("⚠️ 429 response body: \(body ?? "<empty>", privacy: .public)")
            throw AIProcessingError.rateLimited(retryAfter: retryAfter, apiMessage: body)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = decodeErrorMessage(from: data) ?? "Unknown API error"
            throw AIProcessingError.requestFailed(statusCode: httpResponse.statusCode, message: message)
        }

        let chatResponse: OpenAIChatCompletionResponse
        do {
            chatResponse = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw AIProcessingError.invalidResponse(raw: raw)
        }

        guard let content = chatResponse.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw AIProcessingError.invalidResponse(raw: raw)
        }

        let decodedResponse = try decodeAIResponse(from: content)
        let validated = try validate(response: decodedResponse, job: job)

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
        logger.info("✅ AI processed job \(job.id ?? -1) in \(latencyMs)ms")

        return AIProcessingSuccess(response: validated, model: model, latencyMs: latencyMs)
    }

    private func resolvedAPIKey() throws -> String {
        if let key = UserDefaults.standard.string(forKey: "openai.apiKey")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }

        if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envKey.isEmpty {
            return envKey
        }

        throw AIProcessingError.missingAPIKey
    }

    private func resolvedModel() -> String {
        let configured = UserDefaults.standard.string(forKey: "openai.model")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (configured?.isEmpty == false) ? configured! : "gpt-4.1-mini"
    }

    private func buildRequestBody(job: CaptureJob, model: String, existingDefinition: String? = nil) -> OpenAIChatCompletionRequest {
        var systemPrompt = """
        你是英语学习助手。请仅输出合法 JSON，不要附加解释、markdown 或代码块。
        你需要返回字段：lemma, surface_form, phonetic, definition, sentence_translation, word_in_translation, needs_review, confidence_notes。
        word_in_translation 是 sentence_translation 中对应 surface_form 含义的中文词语（用于高亮显示），必须是 sentence_translation 的子串。所有字段均为纯文本，禁止使用 markdown 格式（如 **加粗** 或 *斜体*）。
        definition 必须是中英双语释义，格式为「中文释义\\n英文释义」，例如「捕获；夺取\\nto capture; to seize」。中文在前，英文在后，用换行符分隔。多个义项用分号分隔。
        若不确定请把 needs_review 设为 true，禁止编造。
        """

        if let existingDefinition, !existingDefinition.isEmpty {
            systemPrompt += """

            该单词已有释义：「\(existingDefinition)」。
            请根据当前语境判断：如果是新义项，追加到已有义项后。无论是否有新义项，最终 definition 都必须符合中英双语格式（中文释义\\n英文释义）。如果已有释义不是双语格式，请转换为双语格式。
            """
        }

        let userPrompt = """
        selected_text: \(job.selectedText)
        sentence_context: \(job.sentence ?? "")

        输出 JSON。
        """

        return OpenAIChatCompletionRequest(
            model: model,
            temperature: 0.2,
            responseFormat: .init(type: "json_object"),
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ]
        )
    }

    private func decodeAIResponse(from content: String) throws -> AIResponse {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawJSON: String

        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            if lines.count >= 3 {
                rawJSON = lines.dropFirst().dropLast().joined(separator: "\n")
            } else {
                rawJSON = trimmed
            }
        } else {
            rawJSON = trimmed
        }

        guard let data = rawJSON.data(using: .utf8) else {
            throw AIProcessingError.invalidResponse(raw: trimmed)
        }

        do {
            return try JSONDecoder().decode(AIResponse.self, from: data)
        } catch {
            throw AIProcessingError.invalidResponse(raw: trimmed)
        }
    }

    private func validate(response: AIResponse, job: CaptureJob) throws -> AIResponse {
        let lemma = response.lemma.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lemma.isEmpty else {
            throw AIProcessingError.schemaValidationFailed(field: "lemma", reason: "empty")
        }

        let definition = response.definition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !definition.isEmpty else {
            throw AIProcessingError.schemaValidationFailed(field: "definition", reason: "empty")
        }

        let sentence = job.sentence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? job.selectedText
        guard !sentence.isEmpty else {
            throw AIProcessingError.schemaValidationFailed(field: "sentence", reason: "empty")
        }

        let surface = response.surfaceForm.trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceForm = surface.isEmpty ? job.selectedText : surface

        let phonetic = normalizeOptional(response.phonetic)
        let sentenceTranslation = normalizeOptional(response.sentenceTranslation)
        let wordInTranslation = normalizeOptional(response.wordInTranslation)
        let confidenceNotes = normalizeOptional(response.confidenceNotes)

        return AIResponse(
            lemma: lemma,
            surfaceForm: surfaceForm,
            phonetic: phonetic,
            definition: definition,
            sentence: sentence,
            sentenceSource: nil,
            sentenceTranslation: sentenceTranslation,
            wordInTranslation: wordInTranslation,
            needsReview: response.needsReview,
            confidenceNotes: confidenceNotes
        )
    }

    private func normalizeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "**", with: "")
        return trimmed.isEmpty ? nil : trimmed
    }

    private func decodeErrorMessage(from data: Data) -> String? {
        guard let payload = try? JSONDecoder().decode(OpenAIErrorPayload.self, from: data) else {
            return String(data: data, encoding: .utf8)
        }
        return payload.error?.message
    }
}

private struct OpenAIChatCompletionRequest: Encodable {
    struct ResponseFormat: Encodable {
        let type: String
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let temperature: Double
    let responseFormat: ResponseFormat
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case temperature
        case responseFormat = "response_format"
        case messages
    }
}

private struct OpenAIChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct OpenAIErrorPayload: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
    }

    let error: ErrorBody?
}
