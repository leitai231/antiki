import SwiftUI
import KeyboardShortcuts

// MARK: - Sidebar Selection

enum SidebarItem: Hashable {
    case allWords
    case folder(Int64)
    case dueForReview
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var coordinator = CaptureCoordinator.shared
    @ObservedObject private var backupService = BackupService.shared
    @State private var sidebarSelection: SidebarItem?
    @State private var selectedWordIDs: Set<Int64> = []

    private var selectedWord: Word? {
        guard selectedWordIDs.count == 1, let id = selectedWordIDs.first else { return nil }
        return coordinator.allWords.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(coordinator: coordinator, selection: $sidebarSelection)
        } content: {
            contentView
        } detail: {
            if let word = selectedWord {
                WordDetailView(word: word, coordinator: coordinator)
                    .id(word.id)
            } else {
                ContentUnavailableView {
                    Label("选择一个单词", systemImage: "character.book.closed")
                } description: {
                    Text("从列表中选择单词查看详情")
                        .font(.callout)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 400)
        .overlay(alignment: .bottom) {
            if let toast = coordinator.toastMessage {
                HStack(spacing: 12) {
                    Text(toast)
                        .font(.callout)
                    if coordinator.canUndo {
                        Button("撤销") {
                            Task {
                                await coordinator.undoLastDelete()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 4)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.25), value: coordinator.toastMessage)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.toastMessage)
        .alert(item: $backupService.launchAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好的")) {
                    backupService.clearLaunchAlert()
                }
            )
        }
        .task {
            backupService.loadLaunchRestoreResultIfNeeded()
            await coordinator.loadAllWords()
            await coordinator.loadFolders()
            // Default to Inbox on launch
            if sidebarSelection == nil, let inbox = coordinator.folders.first(where: { $0.isSystem }), let id = inbox.id {
                sidebarSelection = .folder(id)
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch sidebarSelection {
        case .allWords, nil:
            WordListView(coordinator: coordinator, selectedWordIDs: $selectedWordIDs, folderId: nil)
        case .folder(let folderId):
            WordListView(coordinator: coordinator, selectedWordIDs: $selectedWordIDs, folderId: folderId)
        case .dueForReview:
            ContentUnavailableView {
                Label("即将推出", systemImage: "arrow.clockwise")
            } description: {
                Text("复习功能正在开发中")
                    .font(.callout)
            }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var coordinator: CaptureCoordinator
    @Binding var selection: SidebarItem?
    @State private var isCreatingFolder = false
    @State private var renamingFolder: Folder?

    private var inboxFolder: Folder? {
        coordinator.folders.first { $0.isSystem }
    }

    private var userFolders: [Folder] {
        coordinator.folders.filter { !$0.isSystem }
    }

    var body: some View {
        List(selection: $selection) {
            // Inbox (system folder, always first)
            if let inbox = inboxFolder, let inboxId = inbox.id {
                folderRow(inbox)
                    .tag(SidebarItem.folder(inboxId))
            }

            // User-created folders
            if !userFolders.isEmpty {
                Section("文件夹") {
                    ForEach(userFolders) { folder in
                        if let folderId = folder.id {
                            folderRow(folder)
                                .tag(SidebarItem.folder(folderId))
                                .contextMenu {
                                    Button("重命名…") {
                                        renamingFolder = folder
                                    }
                                    Divider()
                                    Button("删除", role: .destructive) {
                                        Task {
                                            if case .folder(let selectedId) = selection, selectedId == folderId {
                                                selection = .allWords
                                            }
                                            await coordinator.deleteFolder(folder)
                                        }
                                    }
                                }
                        }
                    }
                }
            }

            Divider()

            // All Words (virtual, lower priority)
            Label {
                HStack {
                    Text("全部单词")
                    Spacer()
                    if !coordinator.allWords.isEmpty {
                        Text("\(coordinator.allWords.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "book")
            }
            .tag(SidebarItem.allWords)

            // Due for review (placeholder)
            Label("待复习", systemImage: "arrow.clockwise")
                .tag(SidebarItem.dueForReview)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
        .safeAreaInset(edge: .bottom) {
            Button {
                isCreatingFolder = true
            } label: {
                Label("新建文件夹", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .sheet(isPresented: $isCreatingFolder) {
            NewFolderSheet(coordinator: coordinator, isPresented: $isCreatingFolder)
        }
        .sheet(item: $renamingFolder) { folder in
            RenameFolderSheet(coordinator: coordinator, folder: folder, isPresented: Binding(
                get: { renamingFolder != nil },
                set: { if !$0 { renamingFolder = nil } }
            ))
        }
    }

    @ViewBuilder
    private func folderRow(_ folder: Folder) -> some View {
        let count = coordinator.folderWordCounts[folder.id!] ?? 0
        Label {
            HStack {
                Text(folder.name)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: folder.isSystem ? "tray" : "folder")
        }
        .dropDestination(for: WordDragPayload.self) { payloads, _ in
            let wordIds = Set(payloads.map(\.wordId))
            Task {
                await coordinator.moveWords(wordIds, toFolder: folder)
            }
            return true
        }
    }
}

// MARK: - New Folder Sheet

struct NewFolderSheet: View {
    @ObservedObject var coordinator: CaptureCoordinator
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("新建文件夹")
                .font(.headline)
            TextField("文件夹名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Check for duplicate name
        if coordinator.folders.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            errorMessage = "文件夹名称已存在"
            return
        }
        Task {
            await coordinator.createFolder(name: trimmed)
            isPresented = false
        }
    }
}

// MARK: - Rename Folder Sheet

struct RenameFolderSheet: View {
    @ObservedObject var coordinator: CaptureCoordinator
    let folder: Folder
    @Binding var isPresented: Bool
    @State private var name: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("重命名文件夹")
                .font(.headline)
            TextField("文件夹名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { rename() }
            HStack {
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("确定") { rename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear { name = folder.name }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await coordinator.renameFolder(folder, to: trimmed)
            isPresented = false
        }
    }
}

// MARK: - Capture List

enum CaptureFilter {
    case pending, processing, failed, needsReview
}

struct CaptureListView: View {
    @ObservedObject var coordinator: CaptureCoordinator
    let filter: CaptureFilter?

    var filteredCaptures: [CaptureJob] {
        guard let filter else { return coordinator.recentCaptures }
        switch filter {
        case .pending:
            return coordinator.recentCaptures.filter { $0.status == .pending }
        case .processing:
            return coordinator.recentCaptures.filter { $0.status == .processing }
        case .failed:
            return coordinator.recentCaptures.filter { $0.status == .failed }
        case .needsReview:
            return coordinator.recentCaptures.filter { $0.status == .completed && $0.needsReview }
        }
    }

    var body: some View {
        if filteredCaptures.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptyIcon)
            } description: {
                if filter == nil {
                    VStack(spacing: 8) {
                        Text("按 Cmd+Shift+Z 开始采集生词")
                        Text("1. 选中包含生词的句子")
                        Text("2. 按 Cmd+Shift+Z 选择生词")
                    }
                    .font(.callout)
                } else {
                    Text("没有符合条件的记录")
                        .font(.callout)
                }
            }
        } else {
            List(filteredCaptures) { job in
                CaptureJobRow(job: job, coordinator: coordinator)
            }
            .navigationTitle(navTitle)
            .navigationDestination(for: Word.self) { word in
                WordDetailView(word: word, coordinator: coordinator)
            }
        }
    }

    private var navTitle: String {
        switch filter {
        case nil: return "最近采集"
        case .pending: return "等待中"
        case .processing: return "处理中"
        case .failed: return "失败"
        case .needsReview: return "待确认"
        }
    }

    private var emptyTitle: String {
        filter == nil ? "还没有采集" : "没有记录"
    }

    private var emptyIcon: String {
        filter == nil ? "text.badge.plus" : "tray"
    }
}

// MARK: - Capture Job Row

struct CaptureJobRow: View {
    let job: CaptureJob
    @ObservedObject var coordinator: CaptureCoordinator
    @State private var showingReview = false
    @State private var linkedWord: Word?

    var body: some View {
        Group {
            if let word = linkedWord {
                NavigationLink(value: word) {
                    rowContent
                }
            } else {
                rowContent
            }
        }
        .task(id: job.status) {
            if job.status == .completed {
                linkedWord = await coordinator.wordForJob(job)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 4) {
                // Word
                HStack(spacing: 6) {
                    Text(job.selectedText)
                        .font(.headline)

                    if job.status == .completed && job.needsReview {
                        Text("待确认")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yellow.opacity(0.2))
                            .foregroundStyle(.yellow)
                            .clipShape(Capsule())
                    }

                    if job.retryCount > 0 && job.status != .failed {
                        Text("重试×\(job.retryCount)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }

                // Error info for failed jobs
                if job.status == .failed, let errorMessage = job.errorMessage {
                    HStack(spacing: 4) {
                        if let category = job.errorCategory {
                            Text(errorCategoryLabel(category))
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.15))
                                .foregroundStyle(.red)
                                .clipShape(Capsule())
                        }
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                // Sentence preview
                if let sentence = job.sentence {
                    Text(sentence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Source info
                HStack(spacing: 8) {
                    Label(job.sourceApp, systemImage: "globe")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let url = job.sourceUrl, let host = URL(string: url)?.host {
                        Label(host, systemImage: "link")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(job.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }

            // Review button for needs_review jobs
            if job.status == .completed && job.needsReview {
                Button("审阅") {
                    showingReview = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.yellow)
            }

            // Retry button for failed jobs
            if job.status == .failed {
                VStack(spacing: 4) {
                    Button("重试") {
                        Task {
                            await coordinator.retryJob(job)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if job.retryCount > 0 {
                        Text("已重试 \(job.retryCount) 次")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingReview) {
            ReviewDetailView(job: job, coordinator: coordinator)
        }
    }

    private func errorCategoryLabel(_ category: String) -> String {
        switch category {
        case "config": return "配置"
        case "network": return "网络"
        case "rate_limit": return "限流"
        case "api": return "API"
        case "schema": return "格式"
        case "database": return "数据库"
        case "processing": return "处理"
        default: return category
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.orange)
        case .processing:
            ProgressView()
                .scaleEffect(0.7)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gear")
                }

            ShortcutSettingsView()
                .tabItem {
                    Label("快捷键", systemImage: "keyboard")
                }

            AISettingsView()
                .tabItem {
                    Label("AI", systemImage: "brain")
                }
        }
        .frame(width: 460, height: 390)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var backupService = BackupService.shared
    @ObservedObject private var hotkeyHandler = HotkeyHandler.shared

    var body: some View {
        Form {
            Section("辅助功能") {
                HStack {
                    if hotkeyHandler.isAccessibilityGranted {
                        Label("已授权", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("未授权", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if !hotkeyHandler.isAccessibilityGranted {
                        Button("打开设置") {
                            PermissionsManager().openAccessibilitySettings()
                        }
                    }
                }
                Text("授予辅助功能权限后，可直接读取选中文字，无需先复制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("采集") {
                Toggle("采集后显示通知", isOn: .constant(true))
                Toggle("自动处理新采集", isOn: .constant(true))
            }

            Section("隐私") {
                Toggle("发送上下文给 AI", isOn: .constant(true))
                Toggle("保存来源 URL", isOn: .constant(true))
            }

            Section("数据") {
                VStack(alignment: .leading, spacing: 8) {
                    Button(backupService.isExporting ? "导出中…" : "导出备份…") {
                        Task {
                            await backupService.beginExportFlow()
                        }
                    }
                    .disabled(backupService.isBusy)

                    Button(backupService.isPreparingRestore ? "准备恢复中…" : "从备份恢复…") {
                        backupService.beginRestoreFlow()
                    }
                    .disabled(backupService.isBusy)

                    Text("仅备份词库 SQLite 数据，不包含 API Key、快捷键或其他设置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("从备份恢复会覆盖当前词库，应用会退出，并在下次启动前完成替换。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            Section("采集快捷键") {
                KeyboardShortcuts.Recorder("采集生词:", name: .captureWords)
                Text("选中文字后，按此快捷键弹出选词面板")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AISettingsView: View {
    @AppStorage("openai.apiKey") private var apiKey = ""
    @AppStorage("openai.model") private var model = "gpt-4.1-mini"

    var body: some View {
        Form {
            Section("OpenAI API") {
                SecureField("API Key", text: $apiKey)
                Picker("模型", selection: $model) {
                    Text("GPT-4.1 Mini（最均衡）").tag("gpt-4.1-mini")
                    Text("GPT-4.1 Nano（最快）").tag("gpt-4.1-nano")
                    Text("GPT-4.1（好而慢）").tag("gpt-4.1")
                    Text("GPT-4o Mini（第二均衡）").tag("gpt-4o-mini")
                }
                Text("未配置时可通过环境变量 OPENAI_API_KEY 提供。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

#Preview {
    ContentView()
}
