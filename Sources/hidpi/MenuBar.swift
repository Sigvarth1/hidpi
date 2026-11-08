import AppKit
import CoreGraphics

final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let restore = RestoreCoordinator()
    let shortcuts = Shortcuts()
    private lazy var settings = SettingsWindow(app: self)
    private var wakeObserver: NSObjectProtocol?
    private var callbackRegistered = false
    private let suppressRestore: Bool
    private let openSettings: Bool
    private var lastIssue: String?
    /// Uptime of the last wake, connect, or disconnect. macOS itself may drop HiDPI modes around
    /// these events, so mode changes shortly afterwards are never treated as user choices.
    private var lastTopologyChange: TimeInterval = 0
    private var adoptionIDs = Set<CGDirectDisplayID>()
    private var adoptionScheduled = false
    private static let topologySettleSeconds: TimeInterval = 15
    private static let systemSettingsBundleID = "com.apple.systempreferences"
    private static let displayCallback: CGDisplayReconfigurationCallBack = { display, flags, context in
        guard let context, !flags.contains(.beginConfigurationFlag) else { return }
        let app = Unmanaged<MenuBarApp>.fromOpaque(context).takeUnretainedValue()
        let added = flags.contains(.addFlag) || flags.contains(.enabledFlag)
        let topology = added || flags.contains(.removeFlag) || flags.contains(.disabledFlag)
        let modeChanged = flags.contains(.setModeFlag)
        DispatchQueue.main.async {
            if topology { app.lastTopologyChange = ProcessInfo.processInfo.systemUptime }
            // Only the monitor that appeared is restored; other monitors keep their current modes.
            if added { app.scheduleRestoreIfEnabled(displays: [display]) }
            else if modeChanged && !topology { app.noteExternalModeChange(display) }
        }
    }

    init(suppressRestore: Bool = false, openSettings: Bool = false) { self.suppressRestore = suppressRestore; self.openSettings = openSettings }
    static func run(suppressRestore: Bool = false, openSettings: Bool = false) {
        let application = NSApplication.shared
        let delegate = MenuBarApp(suppressRestore: suppressRestore, openSettings: openSettings)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.finishLaunching()
            application.run()
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "HiDPI display scaling")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "HiDPI — Display scaling"
        menu.delegate = self
        statusItem.menu = menu
        restore.onComplete = { [weak self] results in
            self?.lastIssue = results.filter { $0.isProblem }.map { $0.description }.joined(separator: "\n")
            self?.updateStatus()
        }
        shortcuts.onAction = { [weak self] action in self?.handleShortcut(action) }
        if !suppressRestore { shortcuts.configure(enabled: Preferences.store.bool("shortcutsEnabled")) }
        callbackRegistered = CGDisplayRegisterReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque()) == .success
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lastTopologyChange = ProcessInfo.processInfo.systemUptime
            self?.scheduleRestoreIfEnabled(displays: nil)
        }
        if !suppressRestore && Preferences.store.bool("restoreOnStartup") { restore.schedule(displays: nil) }
        if openSettings { DispatchQueue.main.async { [weak self] in self?.showSettings() } }
    }
    private func installApplicationMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "HiDPI")
        action("Settings…", #selector(showSettings), in: applicationMenu).keyEquivalent = ","
        action("Quit HiDPI", #selector(quit), in: applicationMenu).keyEquivalent = "q"
        applicationItem.submenu = applicationMenu; main.addItem(applicationItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let commands: [(String, Selector, String)] = [
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")
        ]
        for (title, selector, key) in commands { editMenu.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        editItem.submenu = editMenu; main.addItem(editItem)
        NSApp.mainMenu = main
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        restore.cancel()
        if callbackRegistered { CGDisplayRemoveReconfigurationCallback(Self.displayCallback, Unmanaged.passUnretained(self).toOpaque()) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never block logout or shutdown: revert an open preview, then quit. If the revert fails,
        // the preview's app-only scope still makes macOS restore the previous mode on exit.
        if SafeSwitch.isActive { SafeSwitch.revertActivePreview() }
        return .terminateNow
    }
    private func scheduleRestoreIfEnabled(displays: Set<CGDirectDisplayID>?) {
        guard !suppressRestore, !SafeSwitch.isActive, Preferences.store.bool("restoreOnWake"), !Preferences.store.bool("pauseRestore") else { return }
        restore.schedule(displays: displays)
    }
    private func noteExternalModeChange(_ display: CGDirectDisplayID) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !suppressRestore, !SafeSwitch.isActive, Preferences.store.bool("adoptSystemSettings"),
              now - lastTopologyChange > Self.topologySettleSeconds,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.systemSettingsBundleID else { return }
        adoptionIDs.insert(display)
        guard !adoptionScheduled else { return }
        adoptionScheduled = true
        // Let the reconfiguration settle before reading the new mode.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.adoptExternalChanges() }
    }
    private func adoptExternalChanges() {
        let ids = adoptionIDs
        adoptionIDs.removeAll(); adoptionScheduled = false
        guard !SafeSwitch.isActive, ProcessInfo.processInfo.systemUptime - lastTopologyChange > Self.topologySettleSeconds else { return }
        Preferences.adoptCurrentModes(displayIDs: ids)
    }
    func preferencesChanged() {
        restore.cancel()
        // Inspection sessions (--no-restore) keep shortcuts off regardless of the saved setting.
        shortcuts.configure(enabled: !suppressRestore && Preferences.store.bool("shortcutsEnabled"))
        updateStatus()
    }
    private func updateStatus() {
        let issue = !(lastIssue ?? "").isEmpty
        statusItem.button?.image = NSImage(systemSymbolName: issue ? "display.trianglebadge.exclamationmark" : "display",
                                          accessibilityDescription: issue ? "HiDPI — restore needs attention" : "HiDPI display scaling")
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "HiDPI")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = issue ? lastIssue : "HiDPI — Display scaling"
    }
    private func heading(_ title: String, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false; menu.addItem(item)
    }
    @discardableResult
    private func action(_ title: String, _ selector: Selector, in menu: NSMenu, object: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self; item.representedObject = object; menu.addItem(item); return item
    }
    private struct Pick { let id: String; let spec: ModeSpec }
    private func addMode(_ spec: ModeSpec, display: Display, current: ModeSpec?, to menu: NSMenu, label: String? = nil) {
        let item = action(label ?? spec.label, #selector(pick(_:)), in: menu, object: Pick(id: display.stableID, spec: spec))
        item.state = current?.matches(spec) == true ? .on : .off
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let displays = Display.online()
        if displays.isEmpty { heading("No displays accessible", in: menu) }
        for (index, display) in displays.enumerated() {
            let current = display.currentMode?.spec
            let root = NSMenuItem(title: "\(index + 1). \(display.name)\(current.map { " — \($0.size)" } ?? "")", action: nil, keyEquivalent: "")
            root.image = NSImage(systemSymbolName: display.isBuiltin ? "laptopcomputer" : "display", accessibilityDescription: nil)
            let submenu = NSMenu(); root.submenu = submenu; menu.addItem(root)
            heading("Current: \(current?.label ?? "Unknown")", in: submenu)
            let catalog = Mode.catalog(for: display.id)
            var specs = catalog.modes.map { $0.spec }
            if let current, !specs.contains(where: { $0.matches(current) }) { specs.append(current) }
            let recommended = ModeChoices.recommended(specs, nativeWidth: display.nativeWidth,
                                                       nativeHeight: display.nativeHeight, current: current)
            if recommended.isEmpty {
                action("HiDPI unavailable — View Diagnostics…", #selector(showDiagnostics), in: submenu)
            } else {
                submenu.addItem(.separator())
                for (label, spec) in recommended { addMode(spec, display: display, current: current, to: submenu, label: "\(label) — \(spec.size) · \(spec.hz)") }
            }
            submenu.addItem(.separator())
            let favorites = Preferences.store.favorites(id: display.stableID)
            if !favorites.isEmpty {
                heading("Favorites", in: submenu)
                for spec in favorites {
                    if specs.contains(where: { $0.matches(spec) }) { addMode(spec, display: display, current: current, to: submenu) }
                    else { heading("\(spec.label) — unavailable", in: submenu) }
                }
            }
            if let current {
                let favorite = favorites.contains { $0.matches(current) }
                action(favorite ? "Remove Current Mode from Favorites" : "Add Current Mode to Favorites", #selector(toggleFavorite(_:)), in: submenu, object: display.stableID)
                let rates = specs.filter { $0.width == current.width && $0.height == current.height && $0.pixelWidth == current.pixelWidth && $0.pixelHeight == current.pixelHeight }.sorted { $0.refresh > $1.refresh }
                let item = NSMenuItem(title: "Refresh Rate", action: nil, keyEquivalent: "")
                let rateMenu = NSMenu(); item.submenu = rateMenu
                for spec in rates { addMode(spec, display: display, current: current, to: rateMenu, label: spec.hz) }
                submenu.addItem(item)
            }
            let all = NSMenuItem(title: "All Modes", action: nil, keyEquivalent: "")
            let allMenu = NSMenu(); all.submenu = allMenu; submenu.addItem(all)
            for hiDPI in [true, false] {
                let modes = specs.filter { $0.isHiDPI == hiDPI }
                guard !modes.isEmpty else { continue }
                heading(hiDPI ? "HiDPI" : "Standard", in: allMenu)
                for best in ModeChoices.bestPerSize(modes, current: current).reversed() {
                    let size = NSMenuItem(title: best.size, action: nil, keyEquivalent: "")
                    let rates = modes.filter { $0.width == best.width && $0.height == best.height }.sorted { $0.refresh > $1.refresh }
                    size.state = rates.contains { current?.matches($0) == true } ? .on : .off
                    let rateMenu = NSMenu(); size.submenu = rateMenu
                    for spec in rates { addMode(spec, display: display, current: current, to: rateMenu, label: "\(spec.hz) · renders \(spec.pixelWidth) × \(spec.pixelHeight)") }
                    allMenu.addItem(size)
                }
            }
            submenu.addItem(.separator())
            action("Forget Saved Setting", #selector(forget(_:)), in: submenu, object: display.stableID)
        }
        menu.addItem(.separator())
        let profiles = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        let profileMenu = NSMenu(); profiles.submenu = profileMenu; menu.addItem(profiles)
        for (index, profile) in Preferences.store.profiles.enumerated() {
            let shortcut = Preferences.store.bool("shortcutsEnabled") && index < 9 ? "   ⌃⌥⌘\(index + 1)" : ""
            action(profile.name + shortcut, #selector(pickProfile(_:)), in: profileMenu, object: profile.id.uuidString)
        }
        if !Preferences.store.profiles.isEmpty { profileMenu.addItem(.separator()) }
        action("Save Current Setup…", #selector(saveProfile), in: profileMenu)
        action("Manage Profiles…", #selector(showProfiles), in: profileMenu)
        let pause = action("Pause Automatic Restore", #selector(togglePause), in: menu)
        pause.state = Preferences.store.bool("pauseRestore") ? .on : .off
        action("Restore Saved Settings Now", #selector(restoreNow), in: menu)
        if !(lastIssue ?? "").isEmpty { action("Restore Needs Attention…", #selector(showDiagnostics), in: menu) }
        menu.addItem(.separator())
        action("Settings…", #selector(showSettings), in: menu).keyEquivalent = ","
        action("Diagnostics…", #selector(showDiagnostics), in: menu)
        action("About HiDPI", #selector(showAbout), in: menu)
        let quit = action("Quit HiDPI", #selector(quit), in: menu); quit.keyEquivalent = "q"
    }
    func perform(_ selections: [DisplaySelection]) {
        restore.cancel()
        do {
            if try SafeSwitch.run(selections, gui: true) { lastIssue = nil; updateStatus() }
        } catch { showError(error) }
    }
    @objc private func pick(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick else { return }
        do {
            let displays = Display.online().filter { $0.stableID == pick.id }
            guard displays.count == 1, let display = displays.first else { throw CLIError("monitor disconnected or identity is ambiguous") }
            let mode = Mode.resolve(pick.spec, in: Mode.all(for: display.id)) ?? (display.currentMode?.spec.matches(pick.spec) == true ? display.currentMode : nil)
            guard let mode else { throw CLIError("this mode is no longer available") }
            perform([DisplaySelection(display: display, mode: mode)])
        } catch { showError(error) }
    }
    @objc private func toggleFavorite(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let display = Display.online().first(where: { $0.stableID == id }), let current = display.currentMode else { return }
        Preferences.store.toggleFavorite(current.spec, id: id)
    }
    @objc private func forget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let display = Display.online().first(where: { $0.stableID == id }) else { return }
        restore.cancel(); Preferences.forget(display)
    }
    func applyProfile(_ profile: DisplayProfile) {
        do { perform(try Preferences.selections(for: profile, displays: Display.online())) }
        catch { showError(error) }
    }
    @objc private func pickProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let profile = Preferences.store.profiles.first(where: { $0.id.uuidString == id }) else { return }
        applyProfile(profile)
    }
    @objc private func saveProfile() { settings.show(tab: 1); settings.saveCurrentProfile() }
    @objc private func showProfiles() { settings.show(tab: 1) }
    @objc func showSettings() { settings.show(tab: 0) }
    @objc func showDiagnostics() { settings.show(tab: 2) }
    @objc private func togglePause() {
        Preferences.store.set(!Preferences.store.bool("pauseRestore"), for: "pauseRestore")
        restore.cancel()
    }
    @objc func restoreNow() {
        restore.cancel()
        let results = Preferences.restoreAll()
        lastIssue = results.filter { $0.isProblem }.map { $0.description }.joined(separator: "\n")
        updateStatus()
        let alert = NSAlert()
        alert.messageText = "Restore results"
        alert.informativeText = results.isEmpty ? "No displays are accessible." : results.map { $0.description }.joined(separator: "\n")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    private func handleShortcut(_ action: Int) {
        guard !SafeSwitch.isActive, NSApp.modalWindow == nil else { return }
        if action >= 2 {
            let profiles = Preferences.store.profiles
            if profiles.indices.contains(action - 2) { applyProfile(profiles[action - 2]) }
            else { NSSound.beep() }
            return
        }
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = Display.online().first(where: { $0.id == id }), let current = display.currentMode else { return }
        let modes = Mode.all(for: display.id)
        let favorites = Preferences.store.favorites(id: display.stableID).compactMap { Mode.resolve($0, in: modes) }.sorted {
            $0.pointWidth * $0.pointHeight < $1.pointWidth * $1.pointHeight
        }
        guard !favorites.isEmpty else { showError(CLIError("add favorite modes for \(display.name) using its menu first")); return }
        let currentIndex = favorites.firstIndex { $0.spec.matches(current.spec) }
        let index = currentIndex.map { ($0 + (action == 0 ? -1 : 1) + favorites.count) % favorites.count } ?? (action == 0 ? favorites.count - 1 : 0)
        perform([DisplaySelection(display: display, mode: favorites[index])])
    }
    func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "HiDPI could not complete the action"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "HiDPI", .applicationVersion: "2.1", .credits: NSAttributedString(string: "Sharper text. Your scale.\nDisplay modes, favorites, and monitor profiles.")])
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
