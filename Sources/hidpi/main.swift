import Foundation
import AppKit

func usage() {
    print("""
    hidpi 2.1 — Sharper text. Your scale.

    USAGE
      hidpi list                         Attached monitors and stable identities
      hidpi modes [display]              Available modes, including HiDPI
      hidpi set <display> <WxH> [opts]   Preview a mode; revert after 15s unless kept
      hidpi restore                      Restore confirmed settings; report each result
      hidpi forget <display>             Stop restoring this monitor's setting
      hidpi status                       Diagnostics and last restore results
      hidpi settings [--no-restore]       Open the settings window
      hidpi menu [--no-restore]           Menu bar app; optional inspection mode
      hidpi favorite list [display]      List favorite modes
      hidpi favorite toggle <display>    Favorite/unfavorite the current mode
      hidpi profile list                 List profiles (also their shortcut order)
      hidpi profile save <name>          Save the current setup as a new profile
      hidpi profile apply <name> [--yes] Preview a complete profile
      hidpi profile update <name>        Replace a profile with the current setup
      hidpi profile rename <old> <new>   Rename a profile
      hidpi profile delete <name>        Delete a profile
      hidpi clean [opts]                 Back up and remove owned legacy overrides

    DISPLAY
      An index from list, display ID, stable identity, name fragment, main, or all.
      An ambiguous name is rejected. Quote names containing spaces.

    OPTIONS
      --hz <n>           Select a refresh rate
      --lowdpi           Select standard (1x) rendering
      --yes              Explicitly keep a change without a timed prompt
      --dry-run          Preview cleanup without changing files
      --include-foreign  Explicitly include overrides of unknown ownership
      --undo <path>      Restore a cleanup backup (never overwrite an active file)
      --help / --version Work even without access to displays

    Global shortcuts (enable in Settings):
      Control-Option-Command Left/Right: previous/next favorite under the pointer
      Control-Option-Command 1–9: apply profiles in saved order
    """)
}

struct Arguments {
    var values: [String]
    mutating func flag(_ name: String) -> Bool {
        guard let index = values.firstIndex(of: name) else { return false }
        values.remove(at: index); return true
    }
    mutating func option(_ name: String) throws -> String? {
        guard let index = values.firstIndex(of: name) else { return nil }
        guard values.indices.contains(index + 1), !values[index + 1].hasPrefix("--") else { throw CLIError("\(name) needs a value") }
        let value = values[index + 1]; values.removeSubrange(index...index + 1); return value
    }
    func check(_ count: ClosedRange<Int>) throws {
        guard count.contains(values.count), !values.contains(where: { $0.hasPrefix("--") }) else { throw CLIError("unexpected or missing arguments: \(values.joined(separator: " ")); run hidpi --help") }
    }
}

func runCLI(_ input: [String]) throws {
    if input.contains("--help") || input == ["help"] || input == ["-h"] { usage(); return }
    if input == ["--version"] { print("hidpi 2.1"); return }
    guard let command = input.first else {
        if Bundle.main.bundleURL.pathExtension == "app" { MenuBarApp.run() } else { usage() }
        return
    }
    var args = Arguments(values: Array(input.dropFirst()))
    switch command {
    case "menu", "settings":
        let suppress = args.flag("--no-restore"); try args.check(0...0)
        MenuBarApp.run(suppressRestore: suppress, openSettings: command == "settings")
    case "list", "status":
        try args.check(0...0)
        if command == "status" { print(Diagnostics.report()); return }
        let displays = Display.online()
        if displays.isEmpty { print("No displays are accessible in this session."); return }
        for (index, display) in displays.enumerated() {
            print("[\(index + 1)] \(display.name)\(display.isBuiltin ? " (built-in)" : "")")
            print("    Current: \(display.currentMode?.describe ?? "unknown")")
            print("    Identity: \(display.stableID)")
            print("    Display ID: \(display.id); \(display.identityNote)\n")
        }
    case "modes":
        try args.check(0...1)
        for display in try Display.select(args.values.first, from: Display.online()) {
            let catalog = Mode.catalog(for: display.id)
            print("\(display.name) — \(catalog.source)")
            for mode in catalog.modes { print("\(display.currentMode?.spec.matches(mode.spec) == true ? "→" : " ") \(mode.describe)") }
        }
    case "set":
        let yes = args.flag("--yes"), lowDPI = args.flag("--lowdpi")
        let hzString = try args.option("--hz")
        let hz: Double?
        if let hzString {
            guard let value = Double(hzString), value.isFinite, value > 0, value <= 1000 else { throw CLIError("--hz needs a finite number greater than zero and at most 1000") }
            hz = value
        } else { hz = nil }
        try args.check(2...2)
        guard let size = ModeSpec.parseSize(args.values[1]) else { throw CLIError("expected a desktop size such as 1920x1080 or \"1920 × 1080\"") }
        let width = size.width, height = size.height
        let displays = try Display.select(args.values[0], from: Display.online())
        let targets = try displays.map { display -> DisplaySelection in
            do { return DisplaySelection(display: display, mode: try Mode.choose(in: Mode.all(for: display.id), width: width, height: height, hz: hz, lowDPI: lowDPI)) }
            catch { throw CLIError("\(display.name): \(error.localizedDescription)") }
        }
        for target in targets { print("\(target.display.name): \(target.mode.describe)") }
        print(try SafeSwitch.run(targets, gui: false, assumeYes: yes) ? "Settings kept and remembered." : "Previous settings restored.")
    case "restore":
        try args.check(0...0)
        let results = Preferences.restoreAll()
        if results.isEmpty { throw CLIError("no displays are accessible in this session") }
        results.forEach { print($0.description) }
        if results.contains(where: { $0.isProblem }) { throw CLIError("some settings could not be restored; see results above") }
    case "forget":
        try args.check(1...1)
        for display in try Display.select(args.values[0], from: Display.online()) { Preferences.forget(display); print("Forgot saved setting for \(display.name)") }
    case "favorite":
        try args.check(1...2)
        guard let subcommand = args.values.first, ["list", "toggle"].contains(subcommand) else { throw CLIError("use favorite list [display] or favorite toggle <display>") }
        if subcommand == "toggle" && args.values.count != 2 { throw CLIError("favorite toggle needs a display") }
        for display in try Display.select(args.values.count == 2 ? args.values[1] : nil, from: Display.online()) {
            if subcommand == "toggle" {
                guard let current = display.currentMode else { throw CLIError("cannot read \(display.name)'s current mode") }
                Preferences.store.toggleFavorite(current.spec, id: display.stableID)
            }
            print("\(display.name):")
            let favorites = Preferences.store.favorites(id: display.stableID)
            if favorites.isEmpty { print("  No favorites") }
            favorites.forEach { print("  \($0.label)") }
        }
    case "profile":
        guard let subcommand = args.values.first else { throw CLIError("profile needs a subcommand; run hidpi --help") }
        args.values.removeFirst()
        let yes = subcommand == "apply" ? args.flag("--yes") : false
        if subcommand == "list" {
            try args.check(0...0)
            let profiles = Preferences.store.profiles
            if profiles.isEmpty { print("No saved profiles.") }
            for (index, profile) in profiles.enumerated() { print("\(index + 1). \(profile.name) — \(profile.displays.count) monitor(s)") }
            return
        }
        try args.check(subcommand == "rename" ? 2...2 : 1...1)
        let name = args.values[0]
        if subcommand == "save" {
            try Preferences.store.saveProfile(name: name, displays: Preferences.capture(Display.online()))
            print("Saved profile \"\(name)\"."); return
        }
        guard let profile = Preferences.store.profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw CLIError("no profile named \"\(name)\"") }
        switch subcommand {
        case "apply":
            let targets = try Preferences.selections(for: profile, displays: Display.online())
            print(try SafeSwitch.run(targets, gui: false, assumeYes: yes) ? "Profile kept and remembered." : "Previous settings restored.")
        case "update": try Preferences.store.saveProfile(name: profile.name, displays: Preferences.capture(Display.online()), replacing: profile.id); print("Profile updated.")
        case "rename": try Preferences.store.saveProfile(name: args.values[1], displays: profile.displays, replacing: profile.id); print("Profile renamed.")
        case "delete": Preferences.store.deleteProfile(id: profile.id); print("Profile deleted.")
        default: throw CLIError("unknown profile command \"\(subcommand)\"")
        }
    case "clean":
        let dryRun = args.flag("--dry-run"), includeForeign = args.flag("--include-foreign")
        let undo = try args.option("--undo"); try args.check(0...0)
        if let undo {
            guard !includeForeign else { throw CLIError("--include-foreign cannot be combined with --undo") }
            if dryRun { print("Would restore backup \(undo)"); return }
            guard getuid() == 0 else { throw CLIError("cleanup undo requires sudo") }
            try Override.undo(undo); print("Restored backup."); return
        }
        let entries = Override.installed(displays: Display.online())
        let selected = entries.filter { $0.owned || includeForeign }
        for entry in entries where !entry.owned && !includeForeign { print("Skipped unknown ownership: \(entry.path)") }
        if selected.isEmpty { print("No owned overrides to clean."); return }
        guard dryRun || getuid() == 0 else { throw CLIError("cleanup requires sudo; preview with --dry-run") }
        for entry in selected {
            if dryRun { print("Would back up and remove \(entry.path)"); continue }
            let backup = try Override.remove(entry, includeForeign: includeForeign)
            print("Removed \(entry.path)\nBackup: \(backup)\nUndo with: sudo hidpi clean --undo '\(backup)'")
        }
    default: throw CLIError("unknown command \"\(command)\" — run hidpi --help")
    }
}

do { try runCLI(Array(CommandLine.arguments.dropFirst())) }
catch {
    fflush(stdout)
    FileHandle.standardError.write(Data("hidpi: \(error.localizedDescription)\n".utf8))
    exit(1)
}
