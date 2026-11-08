import Foundation
import CoreGraphics

struct RestoreResult {
    enum State: String { case restored, alreadyCorrect, noPreference, unavailable, failed, ambiguous }
    let display: String
    let state: State
    let detail: String
    var needsRetry: Bool { state == .unavailable || state == .failed }
    var isProblem: Bool { needsRetry || state == .ambiguous }
    var description: String { "\(display): \(state.rawValue) — \(detail)" }
}

final class PreferenceStore {
    let defaults: UserDefaults
    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: ["restoreOnStartup": true, "restoreOnWake": true,
                                     "pauseRestore": false, "shortcutsEnabled": false, "adoptSystemSettings": true])
    }
    func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    func set(_ value: Bool, for key: String) { defaults.set(value, forKey: key) }
    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func write<T: Encodable>(_ value: T, key: String) {
        // All persisted types are finite numbers and strings, validated before reaching this point.
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
    func remember(_ spec: ModeSpec, id: String) { write(spec, key: "v2.mode.\(id)") }
    func preferred(id: String) -> ModeSpec? { read(ModeSpec.self, key: "v2.mode.\(id)") }
    func forget(id: String) { defaults.removeObject(forKey: "v2.mode.\(id)") }
    func favorites(id: String) -> [ModeSpec] { read([ModeSpec].self, key: "v2.favorites.\(id)") ?? [] }
    func toggleFavorite(_ spec: ModeSpec, id: String) {
        var modes = favorites(id: id)
        if let index = modes.firstIndex(where: { $0.matches(spec) }) { modes.remove(at: index) }
        else { modes.append(spec) }
        write(modes, key: "v2.favorites.\(id)")
    }
    var profiles: [DisplayProfile] {
        get { read([DisplayProfile].self, key: "v2.profiles") ?? [] }
        set { write(newValue, key: "v2.profiles") }
    }
    func saveProfile(name: String, displays: [String: ModeSpec], replacing id: UUID? = nil) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw CLIError("profile names must contain 1–80 characters") }
        guard !displays.isEmpty else { throw CLIError("no monitor settings to save") }
        var list = profiles
        guard !list.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw CLIError("a profile named \"\(name)\" already exists")
        }
        let profile = DisplayProfile(id: id ?? UUID(), name: name, displays: displays)
        if let index = list.firstIndex(where: { $0.id == profile.id }) { list[index] = profile }
        else { list.append(profile) }
        profiles = list
    }
    func deleteProfile(id: UUID) { profiles = profiles.filter { $0.id != id } }
    func record(_ message: String, for id: String) {
        defaults.set("\(ISO8601DateFormatter().string(from: Date()))  \(message)", forKey: "v2.lastEvent.\(id)")
    }
    func lastEvent(id: String) -> String { defaults.string(forKey: "v2.lastEvent.\(id)") ?? "No restore attempts recorded" }
}

enum Preferences {
    static let store = PreferenceStore(defaults: UserDefaults(suiteName: "local.hidpi") ?? .standard)
    static func remember(_ mode: Mode, for display: Display) { store.remember(mode.spec, id: display.stableID) }
    static func forget(_ display: Display) {
        store.forget(id: display.stableID)
        // Stop a legacy preference from being migrated again after Forget.
        store.defaults.set(true, forKey: "v2.ignoreLegacy.\(display.stableID)")
    }
    static func preferredSpec(for display: Display, among displays: [Display], modes: [Mode], migrateLegacy: Bool = false) -> ModeSpec? {
        if let value = store.preferred(id: display.stableID) { return value }
        guard !store.defaults.bool(forKey: "v2.ignoreLegacy.\(display.stableID)") else { return nil }
        // Old preferences identified a model, not an individual unit. Migrate only if unambiguous.
        guard displays.filter({ $0.vendorID == display.vendorID && $0.productID == display.productID }).count == 1,
              let legacy = store.defaults.string(forKey: "mode.\(display.vendorID).\(display.productID)"),
              let mode = modes.first(where: { $0.spec.legacyKey == legacy }) else { return nil }
        if migrateLegacy {
            store.remember(mode.spec, id: display.stableID)
            store.defaults.removeObject(forKey: "mode.\(display.vendorID).\(display.productID)")
        }
        return mode.spec
    }
    /// Restore remembered modes. `displayIDs` limits the restore (e.g. to a monitor that was just
    /// connected) so other monitors are left alone; `nil` restores every connected monitor.
    @discardableResult
    static func restoreAll(displayIDs: Set<CGDirectDisplayID>? = nil) -> [RestoreResult] {
        let operationLock: OperationLock
        do { operationLock = try OperationLock() }
        catch { return [RestoreResult(display: "HiDPI", state: .failed, detail: error.localizedDescription)] }
        defer { withExtendedLifetime(operationLock) {} }
        let displays = Display.online()
        let targets = displays.filter { displayIDs?.contains($0.id) ?? true }
        var results = [RestoreResult?](repeating: nil, count: targets.count)
        var pending: [(index: Int, selection: DisplaySelection, wanted: ModeSpec)] = []
        for (index, display) in targets.enumerated() {
            let modes = Mode.all(for: display.id)
            if displays.filter({ $0.stableID == display.stableID }).count > 1 {
                results[index] = RestoreResult(display: display.name, state: .ambiguous, detail: "duplicate display identity; automatic restore skipped")
            } else if let wanted = preferredSpec(for: display, among: displays, modes: modes, migrateLegacy: true) {
                if display.currentMode?.spec.matches(wanted) == true {
                    results[index] = RestoreResult(display: display.name, state: .alreadyCorrect, detail: wanted.label)
                } else if let mode = Mode.resolve(wanted, in: modes) {
                    pending.append((index, DisplaySelection(display: display, mode: mode), wanted))
                } else { results[index] = RestoreResult(display: display.name, state: .unavailable, detail: "saved mode \(wanted.label) is unavailable") }
            } else {
                let legacy = store.defaults.string(forKey: "mode.\(display.vendorID).\(display.productID)")
                results[index] = RestoreResult(display: display.name, state: legacy == nil ? .noPreference : .ambiguous,
                                               detail: legacy == nil ? "choose a mode to remember it" : "old model-wide preference cannot be safely matched; choose a mode for this monitor")
            }
        }
        func verified(_ item: (index: Int, selection: DisplaySelection, wanted: ModeSpec)) -> RestoreResult {
            let display = item.selection.display
            return display.currentMode?.spec.matches(item.wanted) == true
                ? RestoreResult(display: display.name, state: .restored, detail: item.wanted.label)
                : RestoreResult(display: display.name, state: .failed, detail: "display did not report the requested mode after restore")
        }
        // One shared transaction means one screen reconfiguration; fall back per monitor so one failure cannot block the rest.
        if pending.count > 1, (try? DisplayConfiguration.apply(pending.map { $0.selection }, scope: .forSession)) != nil {
            for item in pending { results[item.index] = verified(item) }
        } else {
            for item in pending {
                do {
                    try DisplayConfiguration.apply([item.selection], scope: .forSession)
                    results[item.index] = verified(item)
                } catch { results[item.index] = RestoreResult(display: item.selection.display.name, state: .failed, detail: error.localizedDescription) }
            }
        }
        return zip(targets, results).map { display, result in
            let result = result ?? RestoreResult(display: display.name, state: .failed, detail: "restore was not attempted")
            store.record(result.description, for: display.stableID)
            return result
        }
    }

    /// Adopt modes chosen outside HiDPI (System Settings) for monitors HiDPI already restores,
    /// so a later wake or reconnect does not undo the user's newer choice.
    @discardableResult
    static func adoptCurrentModes(displayIDs: Set<CGDirectDisplayID>) -> [String] {
        guard let operationLock = try? OperationLock() else { return [] }
        defer { withExtendedLifetime(operationLock) {} }
        let displays = Display.online()
        var adopted: [String] = []
        for display in displays where displayIDs.contains(display.id) {
            guard displays.filter({ $0.stableID == display.stableID }).count == 1,
                  let current = display.currentMode?.spec,
                  let remembered = store.preferred(id: display.stableID), !remembered.matches(current) else { continue }
            store.remember(current, id: display.stableID)
            store.record("adopted \(current.label) chosen in System Settings", for: display.stableID)
            adopted.append(display.name)
        }
        return adopted
    }
    static func selections(for profile: DisplayProfile, displays: [Display]) throws -> [DisplaySelection] {
        // Validate the complete profile before allowing any display change.
        try profile.displays.sorted(by: { $0.key < $1.key }).map { id, spec in
            let matches = displays.filter { $0.stableID == id }
            guard matches.count == 1, let display = matches.first else { throw CLIError("profile \"\(profile.name)\" needs a missing or ambiguous monitor (\(id))") }
            guard let mode = Mode.resolve(spec, in: Mode.all(for: display.id)) else {
                throw CLIError("\(display.name): profile mode \(spec.label) is unavailable")
            }
            return DisplaySelection(display: display, mode: mode)
        }
    }
    static func capture(_ displays: [Display]) throws -> [String: ModeSpec] {
        var result: [String: ModeSpec] = [:]
        for display in displays {
            guard result[display.stableID] == nil else { throw CLIError("duplicate monitor identity; profile was not saved") }
            guard let mode = display.currentMode else { throw CLIError("cannot read \(display.name)'s current mode") }
            result[display.stableID] = mode.spec
        }
        return result
    }
}
