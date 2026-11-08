import Foundation
import CoreGraphics
import AppKit
import ColorSync
import IOKit.graphics

struct Display {
    let id: CGDirectDisplayID
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let serial: UInt32
    let uuid: String?
    let isBuiltin: Bool
    let nativeWidth: Int
    let nativeHeight: Int
    let nativeIsEstimated: Bool

    var stableID: String {
        // Use the system UUID consistently, even when only one of two identical monitors is connected.
        if let uuid { return "\(vendorID).\(productID).uuid.\(uuid)" }
        if serial != 0 { return "\(vendorID).\(productID).serial.\(serial)" }
        return "\(vendorID).\(productID).session.\(id)"
    }
    var identityNote: String {
        uuid != nil ? "Display UUID (may depend on the connection)" : (serial != 0 ? "Hardware serial fallback" : "Session only; reconnect may require reselection")
    }
    var vendorFolder: String { "DisplayVendorID-" + String(vendorID, radix: 16) }
    var productFile: String { "DisplayProductID-" + String(productID, radix: 16) }
    var currentMode: Mode? { CGDisplayCopyDisplayMode(id).map(Mode.init) }

    static func online() -> [Display] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let displays = ids.prefix(Int(count)).map { id in
            let modes = Mode.publicModes(for: id)
            let native = modes.first { mode in
                guard let cg = mode.cg else { return false }
                return cg.ioFlags & UInt32(kDisplayModeNativeFlag) != 0
            }
            let fallback = modes.filter { !$0.isHiDPI }.max {
                $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
            } ?? CGDisplayCopyDisplayMode(id).map(Mode.init)
            let geometry = native ?? fallback
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            }
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            return Display(id: id, name: screen?.localizedName ?? "Display \(id)",
                           vendorID: CGDisplayVendorNumber(id), productID: CGDisplayModelNumber(id),
                           serial: CGDisplaySerialNumber(id), uuid: uuid, isBuiltin: CGDisplayIsBuiltin(id) == 1,
                           nativeWidth: geometry?.pixelWidth ?? Int(CGDisplayPixelsWide(id)),
                           nativeHeight: geometry?.pixelHeight ?? Int(CGDisplayPixelsHigh(id)),
                           nativeIsEstimated: native == nil)
        }
        return displays
    }

    static func select(_ selector: String?, from displays: [Display]) throws -> [Display] {
        guard !displays.isEmpty else { throw CLIError("no displays found") }
        guard let selector, selector != "all" else { return displays }
        if selector == "main" { return displays.filter { CGDisplayIsMain($0.id) == 1 } }
        if let index = Int(selector), (1...displays.count).contains(index) { return [displays[index - 1]] }
        if let id = UInt32(selector), let display = displays.first(where: { $0.id == id }) { return [display] }
        let exact = displays.filter { $0.stableID == selector }
        if !exact.isEmpty { return exact }
        let matches = displays.filter { $0.name.localizedCaseInsensitiveContains(selector) }
        guard !matches.isEmpty else { throw CLIError("no display matches \"\(selector)\" — run hidpi list") }
        guard matches.count == 1 else { throw CLIError("\"\(selector)\" matches multiple monitors; use an index, stable identity, or all") }
        return matches
    }
}

struct Mode {
    let spec: ModeSpec
    let number: Int32?
    let cg: CGDisplayMode?
    var pointWidth: Int { spec.width }
    var pointHeight: Int { spec.height }
    var pixelWidth: Int { spec.pixelWidth }
    var pixelHeight: Int { spec.pixelHeight }
    var refresh: Double { spec.refresh }
    var isHiDPI: Bool { spec.isHiDPI }
    var key: String { spec.key }
    var describe: String { "\(spec.label) · renders \(pixelWidth) × \(pixelHeight)" }

    init(_ raw: CGS.RawMode) {
        spec = ModeSpec(width: raw.pointWidth, height: raw.pointHeight, pixelWidth: raw.pixelWidth,
                        pixelHeight: raw.pixelHeight, refresh: raw.refresh)
        number = raw.number; cg = nil
    }
    init(_ raw: CGDisplayMode) {
        spec = ModeSpec(width: raw.width, height: raw.height, pixelWidth: raw.pixelWidth,
                        pixelHeight: raw.pixelHeight, refresh: raw.refreshRate)
        number = nil; cg = raw
    }
    // Used by tests and catalog-only presentation; not directly applicable to hardware.
    init(spec: ModeSpec) { self.spec = spec; number = nil; cg = nil }

    struct Catalog {
        let modes: [Mode]
        let source: String
    }
    static func catalog(for id: CGDirectDisplayID) -> Catalog {
        buildCatalog(privateModes: CGS.modes(for: id).map(Mode.init), publicModes: { publicModes(for: id) },
                     current: CGDisplayCopyDisplayMode(id).map(Mode.init)?.spec)
    }
    /// Prefer the private driver list only when it passes validation and contains the mode the
    /// public API reports as current. A shifted descriptor layout would fail that cross-check.
    static func buildCatalog(privateModes: [Mode], publicModes: () -> [Mode], current: ModeSpec?) -> Catalog {
        func fallback(_ reason: String) -> Catalog { Catalog(modes: normalize(publicModes()), source: "CoreGraphics fallback — \(reason)") }
        guard !privateModes.isEmpty else { return fallback("private list unavailable or empty") }
        let modes = normalize(privateModes)
        guard !modes.isEmpty else { return fallback("driver descriptors failed validation") }
        if let current, !modes.contains(where: { $0.spec.sameGeometry(current) }) {
            return fallback("driver list did not include the current mode")
        }
        return Catalog(modes: modes, source: "SkyLight driver list")
    }
    static func normalize(_ raw: [Mode]) -> [Mode] {
        var seen = Set<String>()
        return raw.filter {
            $0.pointWidth >= 640 && $0.pointHeight >= 480 && $0.pixelWidth >= $0.pointWidth
                && $0.pixelHeight >= $0.pointHeight && $0.pixelWidth <= 32768 && $0.pixelHeight <= 32768
                && $0.refresh.isFinite && $0.refresh >= 0 && $0.refresh <= 1000
        }.filter { seen.insert($0.key).inserted }.sorted {
            ($0.pointWidth, $0.pointHeight, $0.pixelWidth, $0.refresh) > ($1.pointWidth, $1.pointHeight, $1.pixelWidth, $1.refresh)
        }
    }
    static func all(for id: CGDirectDisplayID) -> [Mode] { catalog(for: id).modes }
    static func publicModes(for id: CGDirectDisplayID) -> [Mode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return [] }
        return modes.filter { $0.isUsableForDesktopGUI() }.map(Mode.init)
    }
    static func resolve(_ wanted: ModeSpec, in modes: [Mode]) -> Mode? {
        modes.first { $0.spec.matches(wanted) }
    }
    static func choose(in modes: [Mode], width: Int, height: Int, hz: Double?, lowDPI: Bool) throws -> Mode {
        var candidates = modes.filter { $0.pointWidth == width && $0.pointHeight == height }
        if let hz { candidates = candidates.filter { abs($0.refresh - hz) < 0.01 } }
        let hiDPI = candidates.filter { $0.isHiDPI }
        let pool = lowDPI ? candidates.filter { !$0.isHiDPI } : (hiDPI.isEmpty ? candidates : hiDPI)
        guard let mode = pool.max(by: { $0.refresh < $1.refresh }) else {
            throw CLIError("no matching \(width) × \(height) mode\(hz.map { " at \($0) Hz" } ?? "")")
        }
        return mode
    }
}

struct DisplaySelection {
    let display: Display
    let mode: Mode
}

enum DisplayConfiguration {
    /// Stage every monitor in one CoreGraphics transaction before committing anything.
    static func apply(_ selections: [DisplaySelection], scope: CGConfigureOption) throws {
        guard !selections.isEmpty else { return }
        let online = Display.online()
        for selection in selections {
            guard online.contains(where: { $0.id == selection.display.id && $0.stableID == selection.display.stableID }) else {
                throw CLIError("\(selection.display.name) disconnected; configuration cancelled")
            }
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            throw CLIError("could not begin display configuration")
        }
        for selection in selections {
            let mode = selection.mode
            let result: CGError
            if let number = mode.number {
                result = CGS.configure(config, modeNumber: number, display: selection.display.id)
            } else if let cg = mode.cg {
                result = CGConfigureDisplayWithDisplayMode(config, selection.display.id, cg, nil)
            } else { result = .illegalArgument }
            guard result == .success else {
                CGCancelDisplayConfiguration(config)
                throw CLIError("\(selection.display.name) rejected \(mode.spec.label) (\(result.rawValue))")
            }
        }
        let result = CGCompleteDisplayConfiguration(config, scope)
        guard result == .success else { throw CLIError("could not commit display configuration (\(result.rawValue))") }
    }
}
