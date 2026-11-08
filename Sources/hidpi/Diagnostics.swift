import Foundation
import CoreGraphics

enum Diagnostics {
    static func report() -> String {
        let displays = Display.online()
        var lines = ["HiDPI 2.1", ProcessInfo.processInfo.operatingSystemVersionString,
                     "Private API symbols: \(CGS.available ? "available" : "unavailable")",
                     "Automatic restore: \(Preferences.store.bool("pauseRestore") ? "paused" : "active")", ""]
        if displays.isEmpty { lines.append("No displays are accessible in this session.") }
        for (index, display) in displays.enumerated() {
            let catalog = Mode.catalog(for: display.id)
            let preferred = Preferences.preferredSpec(for: display, among: displays, modes: catalog.modes)
            lines += ["[\(index + 1)] \(display.name)\(display.isBuiltin ? " (built-in)" : "")",
                      "  Display ID: \(display.id)", "  Identity: \(display.stableID)",
                      "  Identity source: \(display.identityNote)",
                      "  Panel: \(display.nativeWidth) × \(display.nativeHeight)\(display.nativeIsEstimated ? " (estimated)" : "")",
                      "  Current: \(display.currentMode?.describe ?? "unavailable")",
                      "  Remembered: \(preferred?.label ?? "none")", "  Mode source: \(catalog.source)",
                      "  Available: \(catalog.modes.count) modes; \(catalog.modes.filter { $0.isHiDPI }.count) HiDPI",
                      "  Last restore: \(Preferences.store.lastEvent(id: display.stableID))", ""]
        }
        let entries = Override.installed(displays: displays)
        if !entries.isEmpty {
            lines.append("Legacy overrides (their effect depends on the system and driver):")
            for entry in entries { lines.append("  \(entry.path) [\(entry.owned ? "owned by HiDPI" : "unknown ownership; skipped by default")]") }
            lines.append("Preview cleanup with: hidpi clean --dry-run")
        }
        return lines.joined(separator: "\n")
    }
}
