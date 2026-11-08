import Foundation
import CoreGraphics

@main struct TestRunner {
    static var count = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
        count += 1
        do { guard try condition() else { fatalError("FAIL: \(message)") } }
        catch { fatalError("FAIL: \(message): \(error)") }
    }
    static func throwsError(_ message: String, _ body: () throws -> Void) {
        var failed = false
        do { try body() } catch { failed = true }
        check(failed, message)
    }
    static func spec(_ width: Int = 1920, _ hz: Double = 60, hiDPI: Bool = true) -> ModeSpec {
        ModeSpec(width: width, height: width * 9 / 16, pixelWidth: width * (hiDPI ? 2 : 1), pixelHeight: width * 9 / 16 * (hiDPI ? 2 : 1), refresh: hz)
    }
    static func display(_ id: UInt32 = 1, serial: UInt32 = 10, uuid: String? = nil) -> Display {
        Display(id: id, name: "Test Monitor", vendorID: 1, productID: 2, serial: serial, uuid: uuid,
                isBuiltin: false, nativeWidth: 2560, nativeHeight: 1440, nativeIsEstimated: false)
    }
    static func main() throws {
        try modeTests()
        try preferenceTests()
        try transactionTests()
        coordinatorTests()
        improvementTests()
        try cleanupTests()
        try identityTests()
        print("Passed \(count) assertions (no display changes).")
    }
    static func modeTests() throws {
        let sixty = spec(), fast = spec(1920, 144), low = spec(1920, 144, hiDPI: false)
        let modes = [sixty, fast, low].map { Mode(spec: $0) }
        check(try Mode.choose(in: modes, width: 1920, height: 1080, hz: nil, lowDPI: false).spec == fast, "default prefers fastest HiDPI")
        check(try Mode.choose(in: modes, width: 1920, height: 1080, hz: 60, lowDPI: false).spec == sixty, "explicit refresh retained")
        check(try Mode.choose(in: modes, width: 1920, height: 1080, hz: nil, lowDPI: true).spec == low, "low DPI requested")
        throwsError("unavailable rate fails") { _ = try Mode.choose(in: modes, width: 1920, height: 1080, hz: 120, lowDPI: false) }
        check(ModeChoices.bestPerSize([fast, sixty], current: sixty) == [sixty], "active lower rate stays visible")
        check(!spec(1920, 59.94).key.elementsEqual(sixty.key), "fractional refresh identities remain distinct")
        check(!spec(1920, 59.94).matches(sixty), "59.94 and 60 remain distinct")
        check(spec(1920, 60.001).matches(sixty), "minor timing rounding is tolerated during restore")
        check(!spec(1920, 59).matches(sixty), "different refresh rates do not match")
        check(sixty.hz == "60 Hz", "refresh formatter does not strip integer zeros")
        check(spec(1920, 59.94).hz == "59.94 Hz", "fractional refresh label")
        let wrongAspect = ModeSpec(width: 1600, height: 1200, pixelWidth: 3200, pixelHeight: 2400, refresh: 60)
        let recommended = ModeChoices.recommended([spec(1600), sixty, spec(2560), wrongAspect], nativeWidth: 2560, nativeHeight: 1440, current: sixty)
        check(recommended.count == 3, "three useful scale choices")
        check(!recommended.contains { $0.1 == wrongAspect }, "recommendations exclude wrong aspect ratio")
        check(ModeChoices.recommended([sixty], nativeWidth: 2560, nativeHeight: 1440, current: nil).count == 1, "recommendations never repeat a mode")
        check(ModeChoices.recommended([sixty], nativeWidth: 0, nativeHeight: 0, current: nil).isEmpty, "invalid geometry is safe")
    }
    static func preferenceTests() throws {
        let suite = "local.hidpi.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferenceStore(defaults: defaults)
        let first = display(), second = display(2, serial: 20)
        store.remember(spec(), id: first.stableID); store.remember(spec(2560), id: second.stableID)
        check(store.preferred(id: first.stableID) == spec(), "identical models have separate preferences")
        check(store.preferred(id: second.stableID) == spec(2560), "second monitor setting survives")
        store.toggleFavorite(spec(), id: first.stableID)
        check(store.favorites(id: first.stableID) == [spec()], "add favorite")
        store.forget(id: first.stableID)
        check(store.preferred(id: first.stableID) == nil && store.favorites(id: first.stableID).count == 1, "forget preserves favorites")
        store.toggleFavorite(spec(), id: first.stableID)
        check(store.favorites(id: first.stableID).isEmpty, "remove favorite")
        try store.saveProfile(name: "Work", displays: [first.stableID: spec()])
        let saved = store.profiles[0]
        throwsError("duplicate names rejected") { try store.saveProfile(name: "work", displays: [first.stableID: spec()]) }
        throwsError("empty setup rejected") { try store.saveProfile(name: "Empty", displays: [:]) }
        throwsError("blank name rejected") { try store.saveProfile(name: "  ", displays: [first.stableID: spec()]) }
        try store.saveProfile(name: "Office", displays: [first.stableID: spec(2560)], replacing: saved.id)
        check(store.profiles.count == 1 && store.profiles[0].name == "Office", "rename/update retains profile identity and order")
        let reopened = PreferenceStore(defaults: defaults)
        check(reopened.profiles == store.profiles, "profile serialization round trip")
        store.deleteProfile(id: saved.id)
        check(store.profiles.isEmpty, "delete profile")
        defaults.set(Data("invalid".utf8), forKey: "v2.mode.broken")
        check(store.preferred(id: "broken") == nil, "corrupt preferences handled")
        check(store.bool("restoreOnStartup") && !store.bool("shortcutsEnabled"), "sensible initial settings")
        throwsError("profile missing monitor fails preflight") { _ = try Preferences.selections(for: saved, displays: []) }
    }
    static func transactionTests() throws {
        var events: [String] = []
        let transaction = SwitchTransaction(preview: { events.append("preview") }, commit: { events.append("commit") }, rollback: { events.append("rollback") }, remember: { events.append("remember") })
        try transaction.begin()
        check(events == ["preview"], "preview never saves preferences")
        try transaction.revert()
        check(events == ["preview", "rollback"] && transaction.state == .reverted, "timeout/cancel reverts")
        try transaction.revert()
        check(events.count == 2, "revert idempotent")
        throwsError("cannot keep reverted preview") { try transaction.keep() }
        events = []
        let kept = SwitchTransaction(preview: { events.append("preview") }, commit: { events.append("commit") }, rollback: { events.append("rollback") }, remember: { events.append("remember") })
        try kept.begin(); try kept.keep(); try kept.revert()
        check(events == ["preview", "commit", "remember"], "only keep commits and saves; late timeout cannot revert")
        events = []
        let rejected = SwitchTransaction(preview: { events.append("preview"); throw CLIError("driver failure") }, commit: {}, rollback: { events.append("rollback") }, remember: { events.append("remember") })
        throwsError("failed preview reported") { try rejected.begin() }
        check(events == ["preview", "rollback"], "failed preview attempts recovery and never remembers")
        events = []
        let commitFailure = SwitchTransaction(preview: {}, commit: { throw CLIError("commit failed") }, rollback: { events.append("rollback") }, remember: { events.append("remember") })
        try commitFailure.begin()
        throwsError("commit failure reported") { try commitFailure.keep() }
        check(events == ["rollback"], "commit failure restores previous settings without saving")
        let doubleFailure = SwitchTransaction(preview: { throw CLIError("primary error") }, commit: {}, rollback: { throw CLIError("rollback error") }, remember: {})
        do { try doubleFailure.begin(); check(false, "double failure should throw") }
        catch { check(error.localizedDescription.contains("primary error") && error.localizedDescription.contains("rollback error"), "rollback failure preserves both errors") }
        let lock = try OperationLock()
        throwsError("another switch cannot race preview") { _ = try OperationLock() }
        withExtendedLifetime(lock) {}
    }
    static func coordinatorTests() {
        var queued: [() -> Void] = []
        var attempts = 0, completions = 0
        let failed = RestoreResult(display: "Test", state: .failed, detail: "not ready")
        let coordinator = RestoreCoordinator(runRestore: { _ in attempts += 1; return [failed] }, paused: { false }, switching: { false }, scheduler: { _, work in queued.append(work) })
        coordinator.onComplete = { _ in completions += 1 }
        coordinator.schedule()
        while !queued.isEmpty { queued.removeFirst()() }
        check(attempts == 3 && completions == 1, "retries bounded to three with one final result")
        attempts = 0; coordinator.schedule(); coordinator.schedule()
        while !queued.isEmpty { queued.removeFirst()() }
        check(attempts == 3, "reconnect bursts coalesce")
        attempts = 0; coordinator.schedule(); coordinator.cancel()
        while !queued.isEmpty { queued.removeFirst()() }
        check(attempts == 0, "manual actions cancel pending restore")
        var paused = true
        let pausedCoordinator = RestoreCoordinator(runRestore: { _ in attempts += 1; return [] }, paused: { paused }, switching: { false }, scheduler: { _, work in queued.append(work) })
        pausedCoordinator.schedule(); queued.removeFirst()()
        check(attempts == 0 && queued.isEmpty, "paused restore never changes displays")
        paused = false
        var busy = true
        let busyCoordinator = RestoreCoordinator(runRestore: { _ in attempts += 1; return [RestoreResult(display: "Test", state: .alreadyCorrect, detail: "ok")] }, paused: { false }, switching: { busy }, scheduler: { _, work in queued.append(work) })
        busyCoordinator.schedule(); queued.removeFirst()()
        check(attempts == 0, "preview blocks auto restore")
        busy = false; queued.removeFirst()()
        check(attempts == 1 && queued.isEmpty, "restore resumes after preview and stops on success")

        var scopes: [Set<UInt32>?] = []
        let ok = [RestoreResult(display: "Test", state: .restored, detail: "ok")]
        let scoped = RestoreCoordinator(runRestore: { scopes.append($0); return ok }, paused: { false }, switching: { false }, scheduler: { _, work in queued.append(work) })
        let drain = { while !queued.isEmpty { queued.removeFirst()() } }
        scoped.schedule(displays: [7]); drain()
        check(scopes.count == 1 && scopes[0] == [7], "reconnect restores only the added monitor")
        scopes = []; scoped.schedule(displays: [7]); scoped.schedule(displays: [8]); drain()
        check(scopes.count == 1 && scopes[0] == [7, 8], "reconnect bursts merge their monitors")
        scopes = []; scoped.schedule(displays: [7]); scoped.schedule(displays: nil); drain()
        check(scopes.count == 1 && scopes[0] == nil, "wake or startup restore covers every monitor")
        scopes = []; scoped.schedule(displays: [9]); drain()
        check(scopes.count == 1 && scopes[0] == [9], "completed restores do not leak scope into later ones")
        scopes = []; scoped.schedule(displays: nil); scoped.cancel(); scoped.schedule(displays: [3]); drain()
        check(scopes.count == 1 && scopes[0] == [3], "cancel discards pending scope")
    }
    static func improvementTests() {
        check(ModeSpec.parseSize("1920x1080")! == (1920, 1080), "ASCII size parses")
        check(ModeSpec.parseSize("1920 × 1080")! == (1920, 1080), "printed size with × parses")
        check(ModeSpec.parseSize("2560×1440")! == (2560, 1440), "× without spaces parses")
        check(ModeSpec.parseSize("1920X1080")! == (1920, 1080), "uppercase X parses")
        check(ModeSpec.parseSize("1920xx1080") == nil && ModeSpec.parseSize("-1920x1080") == nil
              && ModeSpec.parseSize("100x100") == nil && ModeSpec.parseSize("wide") == nil, "invalid sizes rejected")

        let current = spec(1920, 144)
        let privateModes = [spec(2560, 144), current, spec(1280, 60)].map { Mode(spec: $0) }
        let publicModes = [spec(1920, 60, hiDPI: false), spec(1920, 60, hiDPI: false), ModeSpec(width: 320, height: 200, pixelWidth: 320, pixelHeight: 200, refresh: 60)].map { Mode(spec: $0) }
        var catalog = Mode.buildCatalog(privateModes: privateModes, publicModes: { publicModes }, current: current)
        check(catalog.source == "SkyLight driver list" && catalog.modes.count == 3, "private list used when it contains the current mode")
        check(catalog.modes.map { $0.pointWidth } == [2560, 1920, 1280], "catalog sorted largest first")
        catalog = Mode.buildCatalog(privateModes: privateModes, publicModes: { publicModes }, current: spec(1920, 59.94))
        check(catalog.source == "SkyLight driver list", "cross-check ignores refresh reporting differences")
        catalog = Mode.buildCatalog(privateModes: privateModes, publicModes: { publicModes }, current: spec(1600))
        check(catalog.source.contains("did not include the current mode"), "private list missing current mode is distrusted")
        check(catalog.modes.count == 1, "fallback list is filtered and deduplicated")
        catalog = Mode.buildCatalog(privateModes: [], publicModes: { publicModes }, current: nil)
        check(catalog.source.contains("unavailable") && catalog.modes.count == 1, "empty private list falls back with normalization")
        let garbage = [ModeSpec(width: 3, height: 9, pixelWidth: 1, pixelHeight: 1, refresh: .nan)].map { Mode(spec: $0) }
        catalog = Mode.buildCatalog(privateModes: garbage, publicModes: { publicModes }, current: nil)
        check(catalog.source.contains("failed validation") && catalog.modes.count == 1, "invalid descriptors fall back")

        check(Shortcuts.keys.count == 11, "two favorite and nine profile shortcuts")
        check(Shortcuts.summary(failed: []).hasPrefix("Enabled —"), "all shortcuts registered")
        let partial = Shortcuts.summary(failed: ["←"])
        check(partial.hasPrefix("Enabled, except") && partial.contains("←"), "one conflict keeps the remaining shortcuts")
        check(Shortcuts.summary(failed: Shortcuts.keys.map { $0.name }).hasPrefix("Could not register"), "total failure reported")

        check(SafeSwitch.rollbackScope == .forSession, "reverting a preview never writes a permanent setting")
        check(!SafeSwitch.revertActivePreview(), "quit without a preview has nothing to revert")
    }
    static func cleanupTests() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hidpi-cleanup-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        let vendor = root.appendingPathComponent("DisplayVendorID-1")
        try fm.createDirectory(at: vendor, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let owned = vendor.appendingPathComponent("DisplayProductID-2")
        let foreign = vendor.appendingPathComponent("DisplayProductID-3")
        let data = try PropertyListSerialization.data(fromPropertyList: ["HiDPICreatedBy": "local.hidpi"], format: .xml, options: 0)
        try data.write(to: owned); try Data("foreign data".utf8).write(to: foreign)
        var entries = Override.installed(displays: [], root: root.path)
        check(entries.count == 2 && entries.filter { $0.owned }.count == 1, "cleanup distinguishes ownership")
        let foreignEntry = entries.first { !$0.owned }!
        throwsError("foreign override protected") { _ = try Override.remove(foreignEntry) }
        let backup = try Override.remove(entries.first { $0.owned }!)
        check(!fm.fileExists(atPath: owned.path) && fm.fileExists(atPath: backup), "cleanup moves to backup")
        check(Override.installed(displays: [], root: root.path).count == 1, "backups excluded from subsequent cleanup")
        try Override.undo(backup, root: root.path)
        check(try Data(contentsOf: owned) == data, "undo restores original bytes")
        entries = Override.installed(displays: [], root: root.path)
        let secondBackup = try Override.remove(entries.first { $0.owned }!)
        try Data("new override".utf8).write(to: owned)
        throwsError("undo will not overwrite active replacement") { try Override.undo(secondBackup, root: root.path) }
        check(try String(contentsOf: owned, encoding: .utf8) == "new override", "active replacement preserved")
        throwsError("undo path traversal rejected") { try Override.undo("/tmp/DisplayProductID-2.hidpi-removed-\(UUID().uuidString)", root: root.path) }
        let symlink = vendor.appendingPathComponent("DisplayProductID-9")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: foreign)
        check(!Override.installed(displays: [], root: root.path).contains { $0.path == symlink.path }, "cleanup ignores symlinks")
        let foreignBackup = try Override.remove(foreignEntry, includeForeign: true)
        check(fm.fileExists(atPath: foreignBackup), "explicit foreign cleanup remains reversible")
    }
    static func identityTests() throws {
        let twins = [display(1, serial: 10, uuid: "A"), display(2, serial: 10, uuid: "B")]
        check(twins[0].stableID != twins[1].stableID, "system UUID separates monitors with duplicate serials")
        check(twins[0].stableID == display(999, serial: 10, uuid: "A").stableID, "UUID identity stays consistent after another monitor disconnects")
        check(display(1).stableID == display(999).stableID, "serial identity survives display ID changes")
        check(display(1, serial: 0, uuid: "A").stableID != display(2, serial: 0, uuid: "B").stableID, "UUID separates monitors without serials")
        check(display(1, serial: 0, uuid: nil).stableID != display(2, serial: 0, uuid: nil).stableID, "session fallback avoids model collisions")
        throwsError("ambiguous name rejected") { _ = try Display.select("Test", from: [display(), display(2, serial: 20)]) }
        check(try Display.select("2", from: [display(), display(2, serial: 20)]).first?.serial == 20, "index selects identical monitor")
        throwsError("negative display selector cannot trap") { _ = try Display.select("-1", from: [display()]) }
        throwsError("oversized display ID cannot trap") { _ = try Display.select("9999999999999999999", from: [display()]) }
    }
}
