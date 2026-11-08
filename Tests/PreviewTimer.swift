import AppKit

/// Optional GUI integration check. Does not configure displays or save preferences.
@main struct PreviewTimerTest {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let start = ProcessInfo.processInfo.systemUptime
        let kept = SafeSwitch.confirmInWindow(timeout: 1)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard !kept, elapsed >= 1, elapsed < 6 else {
            fatalError("Preview timer failed: kept=\(kept), elapsed=\(elapsed)")
        }
        print(String(format: "Passed modal preview timeout: reverted decision after %.2f seconds, without changing displays.", elapsed))
    }
}
