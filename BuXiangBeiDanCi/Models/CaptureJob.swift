import Foundation
import GRDB
import UniformTypeIdentifiers
import CoreTransferable

/// Represents a capture job in the processing queue
struct CaptureJob: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    var id: Int64?
    var selectedText: String       // The word user selected
    var normalizedText: String     // Lowercase, trimmed
    var sentence: String?          // The full sentence containing the word
    var sourceApp: String
    var bundleId: String
    var sourceUrl: String?
    var sourceTitle: String?
    var sourceStatus: String
    var captureMethod: String      // "hotkey"
    var status: JobStatus
    var needsReview: Bool
    var errorMessage: String?
    var errorCategory: String?
    var retryCount: Int
    var createdAt: Date
    var processedAt: Date?
    
    enum JobStatus: String, Codable, Sendable {
        case pending
        case processing
        case completed
        case failed
    }
    
    // MARK: - Table Mapping
    
    static let databaseTableName = "capture_jobs"
    
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let selectedText = Column(CodingKeys.selectedText)
        static let normalizedText = Column(CodingKeys.normalizedText)
        static let sentence = Column(CodingKeys.sentence)
        static let sourceApp = Column(CodingKeys.sourceApp)
        static let bundleId = Column(CodingKeys.bundleId)
        static let sourceUrl = Column(CodingKeys.sourceUrl)
        static let sourceTitle = Column(CodingKeys.sourceTitle)
        static let sourceStatus = Column(CodingKeys.sourceStatus)
        static let captureMethod = Column(CodingKeys.captureMethod)
        static let status = Column(CodingKeys.status)
        static let needsReview = Column(CodingKeys.needsReview)
        static let errorMessage = Column(CodingKeys.errorMessage)
        static let errorCategory = Column(CodingKeys.errorCategory)
        static let retryCount = Column(CodingKeys.retryCount)
        static let createdAt = Column(CodingKeys.createdAt)
        static let processedAt = Column(CodingKeys.processedAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Folder Model

struct Folder: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable, Hashable {
    var id: Int64?
    var name: String
    var isSystem: Bool
    var sortOrder: Int
    var createdAt: Date

    static let databaseTableName = "folders"
    static let words = hasMany(Word.self)

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Word Model

struct Word: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable, Hashable {
    var id: Int64?
    var lemma: String
    var phonetic: String?
    var definition: String
    var createdAt: Date
    var updatedAt: Date
    var reviewCount: Int
    var nextReviewAt: Date?
    var familiarity: Int
    var folderId: Int64

    var isProcessing: Bool { definition == "⏳" }
    var isFailed: Bool { definition.hasPrefix("❌") }

    static let databaseTableName = "words"
    static let sources = hasMany(WordSource.self)
    static let folder = belongsTo(Folder.self)

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Word Source Model

struct WordSource: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    var id: Int64?
    var wordId: Int64
    var captureJobId: Int64?
    var surfaceForm: String
    var sentence: String
    var sentenceTranslation: String?
    var wordInTranslation: String?
    var sentenceSource: String
    var sourceApp: String
    var bundleId: String
    var sourceUrl: String?
    var sourceTitle: String?
    var sourceStatus: String
    var aiModel: String?
    var aiLatencyMs: Int?
    var needsReview: Bool
    var capturedAt: Date
    
    static let databaseTableName = "word_sources"
    static let word = belongsTo(Word.self)

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Drag & Drop Payload

struct WordDragPayload: Codable, Transferable {
    let wordId: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wordDragPayload)
    }
}

extension UTType {
    static let wordDragPayload = UTType(exportedAs: "com.buxiangbeidanci.word-drag")
}
