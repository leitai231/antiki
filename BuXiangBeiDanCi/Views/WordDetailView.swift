import SwiftUI

// MARK: - Word Detail View

struct WordDetailView: View {
    let initialWord: Word
    @ObservedObject var coordinator: CaptureCoordinator
    @State private var word: Word
    @State private var sources: [WordSource] = []
    @State private var sourceJobs: [Int64: CaptureJob] = [:]
    @State private var showDeleteConfirmation = false
    @State private var failedJob: CaptureJob?
    @State private var isRetrying = false
    @State private var isEditingDefinition = false
    @State private var editedDefinition = ""

    init(word: Word, coordinator: CaptureCoordinator) {
        self.initialWord = word
        self.coordinator = coordinator
        self._word = State(initialValue: word)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header: lemma + phonetic
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(word.lemma)
                        .font(.largeTitle.bold())
                    if let phonetic = word.phonetic {
                        Text(phonetic)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("删除此单词")
                }

                // Definition
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("释义")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        if !word.isProcessing && !word.isFailed && !isEditingDefinition {
                            Button {
                                editedDefinition = word.definition
                                isEditingDefinition = true
                            } label: {
                                Image(systemName: "pencil.line")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("编辑释义")
                        }
                    }
                    if word.isProcessing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("AI 正在处理，请稍候…")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    } else if word.isFailed {
                        HStack(spacing: 12) {
                            DefinitionText(definition: word.definition, font: .body)
                                .foregroundStyle(.orange)
                            Spacer()
                            if sources.isEmpty, failedJob != nil {
                                Button {
                                    Task { await retryFailedWord() }
                                } label: {
                                    HStack(spacing: 4) {
                                        if isRetrying {
                                            ProgressView()
                                                .scaleEffect(0.6)
                                        }
                                        Text(isRetrying ? "处理中…" : "重新获取")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isRetrying)
                            }
                        }
                    } else if isEditingDefinition {
                        EditableDefinitionEditor(
                            text: $editedDefinition,
                            onCommit: { saveDefinition() },
                            onCancel: { isEditingDefinition = false }
                        )
                    } else {
                        DefinitionText(definition: word.definition, font: .body)
                    }
                }

                // Review info
                if word.reviewCount > 0 || word.familiarity > 0 {
                    HStack(spacing: 16) {
                        Label("复习 \(word.reviewCount) 次", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label("熟悉度 \(word.familiarity)%", systemImage: "chart.bar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Sources
                VStack(alignment: .leading, spacing: 12) {
                    Text("上下文来源（\(sources.count)）")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    if sources.isEmpty {
                        Text("暂无上下文记录")
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(sources) { source in
                            let job = source.captureJobId.flatMap { sourceJobs[$0] }
                            SourceCard(source: source, captureJob: job, coordinator: coordinator)
                        }
                    }
                }
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .textSelection(.enabled)
        .navigationTitle(word.lemma)
        .task {
            await reload()
        }
        .onChange(of: coordinator.wordChangeCounter) {
            Task { await reload() }
        }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
            Button("删除", role: .destructive) {
                guard let wordId = word.id else { return }
                Task {
                    await coordinator.deleteWords(Set([wordId]))
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除「\(word.lemma)」吗？")
        }
    }

    private func reload() async {
        guard let wordId = initialWord.id else { return }
        do {
            // Refresh word data (definition may have been updated)
            if let updated = try await Database.shared.getWord(id: wordId) {
                word = updated
            }
            sources = try await Database.shared.getSourcesForWord(wordId: wordId)
                .sorted { $0.capturedAt > $1.capturedAt }
            sourceJobs = [:]
            for source in sources {
                if let jobId = source.captureJobId,
                   let job = try? await Database.shared.getCaptureJob(id: jobId) {
                    sourceJobs[jobId] = job
                }
            }
            // Load failed job for retry button when no sources exist
            if word.isFailed, sources.isEmpty {
                failedJob = try? await Database.shared.getLatestFailedJob(forLemma: word.lemma)
            } else {
                failedJob = nil
            }
        } catch {
            // silently fail — UI already shows empty state
        }
    }

    private func saveDefinition() {
        let trimmed = editedDefinition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != word.definition else {
            isEditingDefinition = false
            return
        }
        isEditingDefinition = false
        var updated = word
        updated.definition = trimmed
        updated.updatedAt = Date()
        Task {
            try? await Database.shared.updateWord(updated)
            word = updated
            coordinator.wordChangeCounter += 1
        }
    }

    private func retryFailedWord() async {
        guard let job = failedJob else { return }
        isRetrying = true
        await coordinator.retryJob(job)
        isRetrying = false
    }
}

// MARK: - Source Card

struct SourceCard: View {
    let source: WordSource
    let captureJob: CaptureJob?
    @ObservedObject var coordinator: CaptureCoordinator
    @State private var isRetrying = false
    @State private var isEditingTranslation = false
    @State private var editedTranslation = ""

    /// Whether this source has error content (failed job or error text in sentence)
    private var hasError: Bool {
        if let job = captureJob, job.status == .failed { return true }
        return source.sentence.contains("Failed to") ||
               source.sentence.contains("Key not found") ||
               source.sentence.contains("处理作业失败")
    }

    /// User-friendly error message based on error category or content
    private var friendlyErrorMessage: String {
        if let job = captureJob, let category = job.errorCategory {
            switch category {
            case "config":
                return "未配置 OpenAI API Key，请在「设置 → AI」中填写"
            case "network":
                return "网络连接失败，请检查网络后重试"
            case "rate_limit":
                return "请求过于频繁，请稍后重试"
            case "api":
                return "AI 服务暂时不可用，请稍后重试"
            case "schema":
                return "AI 返回数据异常，请重试"
            case "database":
                return "数据异常，请重试"
            default:
                return "处理失败，请重试"
            }
        }
        return "处理失败，请重试"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasError {
                // Friendly error message + retry button
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(friendlyErrorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await retryProcessing() }
                    } label: {
                        HStack(spacing: 4) {
                            if isRetrying {
                                ProgressView()
                                    .scaleEffect(0.6)
                            }
                            Text(isRetrying ? "处理中…" : "重新获取")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRetrying)
                }
                .padding(.vertical, 4)
            } else {
                // Sentence with highlighted surface form
                Text(highlightedSentence)
                    .font(.body)

                // Translation with highlighted word
                if isEditingTranslation {
                    EditableTranslationEditor(
                        text: $editedTranslation,
                        onCommit: { saveTranslation() },
                        onCancel: { isEditingTranslation = false }
                    )
                } else if let translation = source.sentenceTranslation {
                    HStack(alignment: .top, spacing: 6) {
                        Text(highlightedTranslation(translation))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button {
                            editedTranslation = translationWithMarkers(translation)
                            isEditingTranslation = true
                        } label: {
                            Image(systemName: "pencil.line")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("编辑翻译，用 *词语* 标记高亮词")
                    }
                }

                if source.needsReview {
                    Label("待确认", systemImage: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }

            // Source metadata (bottom)
            HStack(spacing: 8) {
                Label(source.sourceApp, systemImage: sourceAppIcon)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let url = source.sourceUrl, let host = URL(string: url)?.host {
                    Label(host, systemImage: "link")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let title = source.sourceTitle, !title.isEmpty {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let model = source.aiModel {
                    Label(model, systemImage: "brain")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(source.capturedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func saveTranslation() {
        let raw = editedTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            isEditingTranslation = false
            return
        }
        isEditingTranslation = false

        // Parse [highlighted word] from the edited text
        let (plainText, highlightedWord) = parseMarkedWord(raw)

        var updated = source
        updated.sentenceTranslation = plainText
        if let word = highlightedWord {
            updated.wordInTranslation = word
        }
        Task {
            try? await Database.shared.updateWordSource(updated)
            coordinator.wordChangeCounter += 1
        }
    }

    /// Wrap the existing wordInTranslation in *asterisks* for editing
    private func translationWithMarkers(_ translation: String) -> String {
        guard let word = source.wordInTranslation,
              let range = translation.range(of: word) else {
            return translation
        }
        return translation.replacingCharacters(in: range, with: "*\(word)*")
    }

    /// Parse `*word*` from text, returning (plain text without markers, extracted word)
    private func parseMarkedWord(_ text: String) -> (String, String?) {
        guard let openMark = text.firstIndex(of: "*") else {
            return (text, nil)
        }
        let afterOpen = text.index(after: openMark)
        guard afterOpen < text.endIndex,
              let closeMark = text[afterOpen...].firstIndex(of: "*"),
              afterOpen < closeMark else {
            return (text, nil)
        }
        let word = String(text[afterOpen..<closeMark])
        let plain = text.replacingCharacters(
            in: openMark...closeMark,
            with: word
        )
        return (plain, word.isEmpty ? nil : word)
    }

    private func retryProcessing() async {
        isRetrying = true
        if let job = captureJob, job.status == .failed {
            await coordinator.retryJob(job)
        } else {
            // No associated job or job isn't failed — create a fresh one
            await coordinator.reprocessSource(source)
        }
        isRetrying = false
    }

    private var highlightedSentence: AttributedString {
        var result = AttributedString(source.sentence)
        if let range = result.range(of: source.surfaceForm, options: .caseInsensitive) {
            result[range].font = .body.bold()
            result[range].foregroundColor = .accentColor
        }
        return result
    }

    private func highlightedTranslation(_ translation: String) -> AttributedString {
        var result = AttributedString(translation)
        if let word = source.wordInTranslation,
           let range = result.range(of: word) {
            result[range].font = .callout.bold()
            result[range].foregroundColor = .accentColor
        }
        return result
    }

    private var sourceAppIcon: String {
        let name = source.sourceApp.lowercased()
        if name.contains("chrome") || name.contains("safari") || name.contains("firefox")
            || name.contains("edge") || name.contains("arc") || name.contains("brave") {
            return "globe"
        }
        switch name {
        case "finder": return "folder"
        case "不想背单词": return "character.book.closed"
        default: return "macwindow"
        }
    }

}

// MARK: - Word List View

struct WordListView: View {
    @ObservedObject var coordinator: CaptureCoordinator
    @Binding var selectedWordIDs: Set<Int64>
    var folderId: Int64?
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteIds: Set<Int64> = []

    private var displayedWords: [Word] {
        guard let folderId else { return coordinator.allWords }
        return coordinator.allWords.filter { $0.folderId == folderId }
    }

    private var navigationTitle: String {
        if let folderId {
            return coordinator.folders.first { $0.id == folderId }?.name ?? "生词本"
        }
        return "生词本"
    }

    var body: some View {
        if displayedWords.isEmpty {
            ContentUnavailableView {
                Label("还没有生词", systemImage: "book")
            } description: {
                Text("采集的单词经 AI 处理后会出现在这里")
                    .font(.callout)
            }
        } else {
            List(selection: $selectedWordIDs) {
                ForEach(displayedWords) { word in
                    WordRow(word: word)
                        .tag(word.id!)
                        .draggable(WordDragPayload(wordId: word.id!))
                        .contextMenu {
                            Menu("移动到…") {
                                ForEach(coordinator.folders) { folder in
                                    if folder.id != folderId {
                                        Button(folder.name) {
                                            guard let wordId = word.id else { return }
                                            Task {
                                                await coordinator.moveWords([wordId], toFolder: folder)
                                                if folderId != nil {
                                                    selectedWordIDs.remove(wordId)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            Divider()
                            if selectedWordIDs.contains(word.id!) && selectedWordIDs.count > 1 {
                                Button("删除 \(selectedWordIDs.count) 个单词", role: .destructive) {
                                    pendingDeleteIds = selectedWordIDs
                                    showDeleteConfirmation = true
                                }
                            } else {
                                Button("删除", role: .destructive) {
                                    let wordId = word.id!
                                    Task {
                                        await coordinator.deleteWords(Set([wordId]))
                                        selectedWordIDs.remove(wordId)
                                    }
                                }
                            }
                        }
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle(navigationTitle)
            .onDeleteCommand {
                handleDelete()
            }
            .confirmationDialog(
                "确认删除",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("删除 \(pendingDeleteIds.count) 个单词", role: .destructive) {
                    let ids = pendingDeleteIds
                    Task {
                        await coordinator.deleteWords(ids)
                        selectedWordIDs.subtract(ids)
                    }
                }
            } message: {
                Text("确定要删除选中的 \(pendingDeleteIds.count) 个单词吗？")
            }
        }
    }

    private func handleDelete() {
        let ids = selectedWordIDs
        guard !ids.isEmpty else { return }
        if ids.count > 1 {
            pendingDeleteIds = ids
            showDeleteConfirmation = true
        } else {
            Task {
                await coordinator.deleteWords(ids)
                selectedWordIDs = []
            }
        }
    }
}

// MARK: - Word Row

struct WordRow: View {
    let word: Word

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(word.lemma)
                    .font(.headline)
                if let phonetic = word.phonetic, !word.isProcessing {
                    Text(phonetic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if word.isProcessing {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("正在获取释义…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if word.isFailed {
                Text(formattedDefinitionCompact(word.definition))
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(formattedDefinitionCompact(word.definition))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Definition Display

/// 详情页：中文行 + 英文 bullet list（悬挂缩进，长文自动换行对齐）
private struct DefinitionText: View {
    let definition: String
    let font: Font

    var body: some View {
        let lines = definition.components(separatedBy: "\n")
        let chineseLine = lines.first ?? ""
        let englishPart = lines.dropFirst().joined(separator: "\n")
        let englishItems = englishPart
            .components(separatedBy: "; ")
            .filter { !$0.isEmpty }

        VStack(alignment: .leading, spacing: 4) {
            if !chineseLine.isEmpty {
                Text(chineseLine)
                    .font(font)
            }
            ForEach(Array(englishItems.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 4) {
                    Text("•")
                        .font(font)
                    Text(item)
                        .font(font)
                }
            }
        }
    }
}

// MARK: - Inline Editors

/// Multi-line editor for word definition with save/cancel buttons
private struct EditableDefinitionEditor: View {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
                .frame(minHeight: 60, maxHeight: 200)
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("保存") { onCommit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}

/// Single-line editor for sentence translation with save/cancel buttons
private struct EditableTranslationEditor: View {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("句子翻译", text: $text)
                .font(.callout)
                .textFieldStyle(.plain)
                .padding(6)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
                .onSubmit { onCommit() }
            HStack(spacing: 8) {
                Text("用 *星号* 标记高亮词")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("保存") { onCommit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}

/// 列表行：紧凑格式，"• " 前缀，lineLimit 自然截断
private func formattedDefinitionCompact(_ definition: String) -> String {
    let lines = definition.components(separatedBy: "\n")
    let chineseLine = lines.first ?? ""
    let englishPart = lines.dropFirst().joined(separator: "\n")
    let englishItems = englishPart
        .components(separatedBy: "; ")
        .filter { !$0.isEmpty }
        .map { "• \($0)" }
        .joined(separator: "\n")
    return englishItems.isEmpty ? chineseLine : "\(chineseLine)\n\(englishItems)"
}
