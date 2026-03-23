import AppKit
import ApplicationServices
import Foundation

struct PermissionsManager {
    func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibilityPrompt() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
