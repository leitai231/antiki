import SwiftUI

/// Detail view for reviewing and editing AI-generated word definitions/translations.
/// Shown as a sheet when user taps a needs_review capture job.
struct ReviewDetailView: View {
    let job: CaptureJob
    @ObservedObject var coordinator: CaptureCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var word: Word?
    @State private var source: WordSource?
    @State private var isLoading = true

    // Editable fields
    @State private var definition: String = ""
    @State private var phonetic: String = ""
    @State private var sentenceTranslation: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("审阅 AI 结果")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            if isLoading {
                Spacer()
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Word header
                        wordHeader

                        Divider()

                        // Editable fields
                        editableFields

                        Divider()

                        // Sentence context (read-only)
                        sentenceSection

                        // Confidence notes
                        if let source, source.sentenceSource == "reconstructed" {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                Text("此例句由 AI 构造，非原文摘录")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                }
                .scrollIndicators(.hidden)

                Divider()

                // Action buttons
                actionButtons
            }
        }
        .frame(width: 480, height: 520)
        .task {
            await loadData()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var wordHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(job.selectedText)
                .font(.title.bold())

            if let word, word.lemma != job.selectedText.lowercased() {
                Text("→ \(word.lemma)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("待确认")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.yellow.opacity(0.2))
                .foregroundStyle(.yellow)
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var editableFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("音标")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("如 /ɪɡˈzæmpəl/", text: $phonetic)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("释义")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $definition)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("句子翻译")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $sentenceTranslation)
                    .font(.body)
                    .frame(minHeight: 40, maxHeight: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }
        }
    }

    @ViewBuilder
    private var sentenceSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("例句上下文")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let sentence = source?.sentence ?? job.sentence {
                Text(sentence)
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if !job.sourceApp.isEmpty {
                HStack(spacing: 6) {
                    Label(job.sourceApp, systemImage: "app")
                    if let url = job.sourceUrl, let host = URL(string: url)?.host {
                        Label(host, systemImage: "link")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack {
            Button("取消") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("确认已审阅") {
                Task {
                    await coordinator.saveReviewEdits(
                        job: job,
                        definition: definition,
                        phonetic: phonetic.isEmpty ? nil : phonetic,
                        sentenceTranslation: sentenceTranslation.isEmpty ? nil : sentenceTranslation
                    )
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    // MARK: - Data Loading

    private func loadData() async {
        guard let jobId = job.id else {
            isLoading = false
            return
        }

        do {
            let loadedSource = try await Database.shared.getWordSourceForJob(captureJobId: jobId)
            source = loadedSource

            if let loadedSource {
                let loadedWord = try await Database.shared.getWord(id: loadedSource.wordId)
                word = loadedWord

                // Pre-fill editable fields from DB data
                definition = loadedWord?.definition ?? ""
                phonetic = loadedWord?.phonetic ?? ""
                sentenceTranslation = loadedSource.sentenceTranslation ?? ""
            }
        } catch {
            // If data loading fails, populate from what we have
            definition = ""
            phonetic = ""
            sentenceTranslation = ""
        }

        isLoading = false
    }
}
