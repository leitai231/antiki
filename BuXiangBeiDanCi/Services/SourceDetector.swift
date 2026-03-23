import AppKit
import os.log

/// Represents the source where text was captured from
struct CaptureSource {
    let app: String
    let bundleId: String
    let url: String?
    let title: String?
    let status: SourceStatus
    
    enum SourceStatus: String {
        case resolved   // All info obtained
        case partial    // Only app info, URL failed
        case failed     // Only basic info
    }
}

/// Detects the current active application as capture source metadata.
class SourceDetector {
    
    private static let logger = Logger(subsystem: "com.blackkingbar.buxiangbeidanci", category: "source")

    /// Phase 0/1: browser URL capture is postponed.
    /// Keep this switch for quick re-enable in later phases.
    private static let isBrowserURLCaptureEnabled = false
    
    /// Supported browsers for URL extraction
    private static let supportedBrowsers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
        "org.mozilla.firefox"
    ]
    
    /// Detect the current source (active app + URL if browser)
    static func detectCurrentSource(preferredApp: NSRunningApplication? = nil) -> CaptureSource {
        // Use the app captured at hotkey trigger when available.
        // Fallback to current frontmost app for callers that don't pass preferredApp.
        guard let frontApp = preferredApp ?? NSWorkspace.shared.frontmostApplication else {
            logger.error("❌ Could not get frontmost application")
            return CaptureSource(
                app: "Unknown",
                bundleId: "unknown",
                url: nil,
                title: nil,
                status: .failed
            )
        }
        
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleId = frontApp.bundleIdentifier ?? "unknown"
        
        logger.info("🖥️ Frontmost app: \(appName) (\(bundleId))")
        
        // Browser URL capture is optional and currently disabled.
        if isBrowserURLCaptureEnabled && supportedBrowsers.contains(bundleId) {
            let (url, title, error) = getBrowserURL(bundleId: bundleId)
            
            if let error = error {
                logger.warning("⚠️ Failed to get browser URL: \(error)")
                return CaptureSource(
                    app: appName,
                    bundleId: bundleId,
                    url: nil,
                    title: nil,
                    status: .partial
                )
            }
            
            return CaptureSource(
                app: appName,
                bundleId: bundleId,
                url: url,
                title: title,
                status: url != nil ? .resolved : .partial
            )
        }
        
        // Non-browser app
        return CaptureSource(
            app: appName,
            bundleId: bundleId,
            url: nil,
            title: nil,
            status: .resolved
        )
    }
    
    /// Get URL from browser using AppleScript
    private static func getBrowserURL(bundleId: String) -> (url: String?, title: String?, error: String?) {
        let script: String
        
        switch bundleId {
        case "com.apple.Safari":
            script = """
            tell application "Safari"
                if (count of windows) > 0 then
                    set currentTab to current tab of front window
                    return {URL of currentTab, name of currentTab}
                end if
            end tell
            """
            
        case "com.google.Chrome":
            script = """
            tell application "Google Chrome"
                if (count of windows) > 0 then
                    set activeTab to active tab of front window
                    return {URL of activeTab, title of activeTab}
                end if
            end tell
            """

        case "com.microsoft.edgemac":
            script = """
            tell application "Microsoft Edge"
                if (count of windows) > 0 then
                    set activeTab to active tab of front window
                    return {URL of activeTab, title of activeTab}
                end if
            end tell
            """
            
        case "company.thebrowser.Browser":  // Arc
            script = """
            tell application "Arc"
                if (count of windows) > 0 then
                    set activeTab to active tab of front window
                    return {URL of activeTab, title of activeTab}
                end if
            end tell
            """

        case "org.mozilla.firefox":
            script = """
            tell application "Firefox"
                if (count of windows) > 0 then
                    set activeTab to active tab of front window
                    return {URL of activeTab, name of activeTab}
                end if
            end tell
            """
            
        default:
            return (nil, nil, "Unsupported browser: \(bundleId)")
        }
        
        return runAppleScript(script)
    }
    
    /// Execute AppleScript and parse result
    private static func runAppleScript(_ source: String) -> (url: String?, title: String?, error: String?) {
        guard let appleScript = NSAppleScript(source: source) else {
            return (nil, nil, "Failed to create AppleScript")
        }
        
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)
        
        if let error = errorDict {
            let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            logger.error("❌ AppleScript error: \(errorMessage)")
            return (nil, nil, errorMessage)
        }
        
        // Parse the result (list of 2 items: URL and title)
        guard result.numberOfItems == 2 else {
            // Might return a single string or nothing
            if let url = result.stringValue {
                return (url, nil, nil)
            }
            return (nil, nil, "Unexpected result format")
        }
        
        let url = result.atIndex(1)?.stringValue
        let title = result.atIndex(2)?.stringValue
        
        return (url, title, nil)
    }
}
