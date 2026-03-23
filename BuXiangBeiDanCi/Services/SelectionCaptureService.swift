import AppKit
import ApplicationServices
import Carbon
import Foundation

// MARK: - Error Type

enum SelectionCaptureError: LocalizedError {
    case accessibilityPermissionMissing
    case emptySelection
    case captureFailed(String)
    case secureContextBlocked

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "需要辅助功能权限才能直接读取选中文字"
        case .emptySelection:
            return "未检测到选中文字"
        case .captureFailed(let reason):
            return reason
        case .secureContextBlocked:
            return "当前应用阻止了文字读取"
        }
    }
}

// MARK: - Selection Capture Service

struct SelectionCaptureService {
    private let permissionsManager: PermissionsManager

    init(permissionsManager: PermissionsManager) {
        self.permissionsManager = permissionsManager
    }

    /// Two-tier capture: AX API → simulated Cmd+C. Fails fast on failure.
    func captureSelectedText(targetApp: NSRunningApplication?) async throws -> String {
        let hasAccessibility = permissionsManager.isAccessibilityGranted()

        // Tier 1: Accessibility API (zero side effects)
        if hasAccessibility {
            if let accessibilityText = captureUsingAccessibility(targetApp: targetApp),
               !accessibilityText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Some apps (browsers, rich-text editors) return text without line breaks.
                // Clipboard copy typically retains structure, so try it when result looks flattened.
                if !accessibilityText.contains(where: \.isNewline) && accessibilityText.count > 50 {
                    if let richerText = try? await captureUsingCopyFallback(),
                       richerText.contains(where: \.isNewline) {
                        return richerText
                    }
                }
                return accessibilityText
            }
        }

        // Tier 2: Simulated Cmd+C (with clipboard snapshot/restore)
        // Let errors propagate so HotkeyHandler can show the correct message.
        do {
            return try await captureUsingCopyFallback()
        } catch let error as SelectionCaptureError {
            // If AX was never attempted due to missing permission, surface that as the root cause
            // so the user gets the "grant accessibility" prompt instead of a generic error.
            if !hasAccessibility {
                throw SelectionCaptureError.accessibilityPermissionMissing
            }
            throw error
        }
    }

    // MARK: - Tier 1: Accessibility API

    private func captureUsingAccessibility(targetApp: NSRunningApplication?) -> String? {
        guard permissionsManager.isAccessibilityGranted() else {
            return nil
        }

        // Try system-wide focused element first
        let systemWide = AXUIElementCreateSystemWide()
        if let focused = copyElementAttribute(.focusedUIElement, from: systemWide),
           let selected = copyStringAttribute(.selectedText, from: focused),
           !selected.isEmpty {
            return selected
        }

        // Fall back to target app's focused element
        let pid: pid_t
        if let app = targetApp {
            pid = app.processIdentifier
        } else if let frontmost = NSWorkspace.shared.frontmostApplication {
            pid = frontmost.processIdentifier
        } else {
            return nil
        }

        let application = AXUIElementCreateApplication(pid)
        if let focused = copyElementAttribute(.focusedUIElement, from: application),
           let selected = copyStringAttribute(.selectedText, from: focused),
           !selected.isEmpty {
            return selected
        }

        return nil
    }

    private func copyElementAttribute(_ attribute: AXAttribute, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
        guard status == .success, let value else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyStringAttribute(_ attribute: AXAttribute, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
        guard status == .success else {
            return nil
        }
        return value as? String
    }

    // MARK: - Tier 2: Simulated Cmd+C

    private func captureUsingCopyFallback() async throws -> String {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(from: pasteboard)
        let baselineChangeCount = pasteboard.changeCount

        try triggerCopyShortcut()
        let changed = try await waitForPasteboardChange(pasteboard: pasteboard, baselineChangeCount: baselineChangeCount)

        defer {
            snapshot.restore(to: pasteboard)
        }

        guard changed else {
            throw SelectionCaptureError.secureContextBlocked
        }

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectionCaptureError.emptySelection
        }

        return text
    }

    private func triggerCopyShortcut() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw SelectionCaptureError.captureFailed("无法创建键盘事件源")
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func waitForPasteboardChange(
        pasteboard: NSPasteboard,
        baselineChangeCount: Int
    ) async throws -> Bool {
        let timeoutNanoseconds: UInt64 = 600_000_000
        let pollNanoseconds: UInt64 = 50_000_000
        let started = DispatchTime.now().uptimeNanoseconds

        while DispatchTime.now().uptimeNanoseconds - started < timeoutNanoseconds {
            if pasteboard.changeCount != baselineChangeCount {
                return true
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }

        return false
    }
}

// MARK: - AX Attribute Keys

private enum AXAttribute: String {
    case focusedUIElement = "AXFocusedUIElement"
    case selectedText = "AXSelectedText"
}

// MARK: - Pasteboard Snapshot

private struct PasteboardSnapshot {
    private let items: [PasteboardItemSnapshot]

    init(from pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map(PasteboardItemSnapshot.init)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else {
            return
        }

        let restoredItems = items.map(\.materializedItem)
        pasteboard.writeObjects(restoredItems)
    }
}

private struct PasteboardItemSnapshot {
    let values: [(String, Data)]

    init(item: NSPasteboardItem) {
        values = item.types.compactMap { type in
            guard let data = item.data(forType: type) else {
                return nil
            }
            return (type.rawValue, data)
        }
    }

    var materializedItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        for (type, data) in values {
            item.setData(data, forType: NSPasteboard.PasteboardType(type))
        }
        return item
    }
}
