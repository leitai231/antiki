import SwiftUI
import AppKit
import KeyboardShortcuts

@main
struct BuXiangBeiDanCiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Main window
        WindowGroup {
            ContentView()
        }
        
        // Settings
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    var wordPickerWindow: NSWindow?
    private var isProgrammaticClose = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("❌ Notification permission error: \(error)")
            }
        }
        
        // Request accessibility permission on first launch
        if !PermissionsManager().isAccessibilityGranted() {
            PermissionsManager().requestAccessibilityPrompt()
        }

        print("✅ BuXiangBeiDanCi launched")
        print("📌 Press Cmd+Shift+Z to capture words")
        
        // Setup observer for showing word picker
        setupWordPickerObserver()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("👋 BuXiangBeiDanCi terminating")
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    private func setupWordPickerObserver() {
        Task { @MainActor in
            // Direct callback: guaranteed synchronous close
            HotkeyHandler.shared.onDismissPicker = { [weak self] in
                self?.hideWordPickerWindow()
            }
            // Async observer: handles show and serves as backup for hide
            for await isShowing in HotkeyHandler.shared.$isShowingPicker.values {
                if isShowing {
                    showWordPickerWindow()
                } else {
                    hideWordPickerWindow()
                }
            }
        }
    }
    
    @MainActor
    private func showWordPickerWindow() {
        if let existingWindow = wordPickerWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create a new window for the word picker
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        panel.title = "不想背单词"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.center()
        
        let contentView = WordPickerPanel(hotkeyHandler: HotkeyHandler.shared)
        panel.contentView = NSHostingView(rootView: contentView)
        
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        wordPickerWindow = panel
    }
    
    @MainActor
    private func hideWordPickerWindow() {
        guard let window = wordPickerWindow else { return }

        isProgrammaticClose = true
        window.close()
        isProgrammaticClose = false
        wordPickerWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard !isProgrammaticClose else { return }

        Task { @MainActor in
            if HotkeyHandler.shared.isShowingPicker {
                HotkeyHandler.shared.cancelCapture()
            }
            wordPickerWindow = nil
        }
    }
}

import UserNotifications
