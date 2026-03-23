import AppKit
import KeyboardShortcuts
import os.log

// MARK: - Hotkey Definition

extension KeyboardShortcuts.Name {
    static let captureWords = Self("captureWords", default: .init(.z, modifiers: [.control, .command]))
}

// MARK: - Hotkey Handler

/// Handles global hotkey (Cmd+Shift+Z) to trigger word capture
@MainActor
class HotkeyHandler: ObservableObject {

    static let shared = HotkeyHandler()

    private let logger = Logger(subsystem: "com.blackkingbar.buxiangbeidanci", category: "hotkey")

    private let permissionsManager = PermissionsManager()
    private lazy var selectionCaptureService = SelectionCaptureService(permissionsManager: permissionsManager)

    /// The app that was active before our hotkey was triggered
    private var previousApp: NSRunningApplication?

    /// Whether the word picker panel is currently showing
    @Published var isShowingPicker = false

    /// Current capture source
    @Published var currentSource: CaptureSource?

    /// Current captured text
    @Published var capturedText: String?

    /// Whether accessibility permission is granted
    @Published var isAccessibilityGranted = false

    private var permissionTimer: Timer?

    private init() {
        isAccessibilityGranted = permissionsManager.isAccessibilityGranted()
        setupHotkey()
        startPermissionPolling()
    }

    deinit {
        permissionTimer?.invalidate()
    }

    private func setupHotkey() {
        KeyboardShortcuts.onKeyUp(for: .captureWords) { [weak self] in
            Task { @MainActor in
                await self?.handleHotkeyTriggered()
            }
        }
        logger.info("✅ Hotkey Cmd+Shift+Z registered")
    }

    private func startPermissionPolling() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAccessibilityGranted = self.permissionsManager.isAccessibilityGranted()
            }
        }
    }

    /// Called when hotkey is triggered
    private func handleHotkeyTriggered() async {
        logger.info("🎯 Hotkey triggered")

        // 1. Record the previous active app BEFORE we become active
        previousApp = NSWorkspace.shared.frontmostApplication
        logger.info("📍 Previous app: \(self.previousApp?.localizedName ?? "unknown")")

        // 2. Get source info from the previous app
        currentSource = SourceDetector.detectCurrentSource(preferredApp: previousApp)

        // 3. Restore source app focus and wait for modifier keys to release
        await prepareSelectionCaptureContext()

        // 4. Capture selected text using three-tier strategy
        let text: String
        do {
            text = try await selectionCaptureService.captureSelectedText(targetApp: previousApp)
        } catch let error as SelectionCaptureError {
            logger.warning("⚠️ Selection capture failed: \(error.localizedDescription)")
            showCaptureError(error)
            return
        } catch {
            logger.warning("⚠️ Unexpected capture error: \(error.localizedDescription)")
            showCaptureError(.captureFailed(error.localizedDescription))
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger.warning("⚠️ Captured text is empty")
            showCaptureError(.emptySelection)
            return
        }

        guard trimmed.count <= 1000 else {
            logger.warning("⚠️ Captured text too long: \(trimmed.count) chars")
            showTooLongAlert()
            return
        }

        capturedText = trimmed
        logger.info("📋 Captured text: \(trimmed.prefix(50))...")

        // 5. Show the word picker panel
        isShowingPicker = true
    }

    /// Restore source app focus and wait for modifier keys to release
    private func prepareSelectionCaptureContext() async {
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier == myPID,
           let restore = previousApp, !restore.isTerminated {
            restore.activate()
            try? await Task.sleep(nanoseconds: 220_000_000)
            return
        }
        // Wait for Cmd+Shift to release so simulated Cmd+C doesn't become Cmd+Shift+C
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    /// Handle when user confirms selected words
    func confirmCapture(words: [String], sentence: String, source: CaptureSource) async {
        logger.info("✅ Capturing \(words.count) words")

        for word in words {
            await CaptureCoordinator.shared.capture(
                word: word,
                sentence: sentence,
                source: source
            )
        }

        // Close the picker
        isShowingPicker = false
        capturedText = nil
        currentSource = nil
        previousApp = nil

        // Show success notification
        showCaptureNotification(count: words.count)
    }

    /// Handle when user cancels
    func cancelCapture() {
        logger.info("❌ Capture cancelled")
        isShowingPicker = false
        capturedText = nil
        currentSource = nil
        previousApp = nil
    }

    // MARK: - Alerts

    private func showCaptureError(_ error: SelectionCaptureError) {
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch error {
        case .accessibilityPermissionMissing:
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = "授予辅助功能权限后，可直接读取选中文字，无需先复制。"
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                permissionsManager.openAccessibilitySettings()
            }
            return
        case .emptySelection:
            alert.messageText = "未检测到选中文字"
            alert.informativeText = "请先选中文字再按快捷键。"
        case .secureContextBlocked:
            alert.messageText = "无法读取文字"
            alert.informativeText = "当前应用阻止了文字读取，请尝试手动复制 (Cmd+C) 后再按快捷键。"
        case .captureFailed(let reason):
            alert.messageText = "采集失败"
            alert.informativeText = reason
        }

        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    private func showTooLongAlert() {
        let alert = NSAlert()
        alert.messageText = "文字太长"
        alert.informativeText = "请选择较短的句子（最多 1000 字符）。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    private func showCaptureNotification(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = "已采集"
        content.body = "成功添加 \(count) 个生词"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                self.logger.error("Failed to show notification: \(error)")
            }
        }
    }
}

import UserNotifications
