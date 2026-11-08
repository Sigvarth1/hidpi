import AppKit
import ServiceManagement

final class SettingsWindow: NSObject {
    private unowned let app: MenuBarApp
    private var window: NSWindow!
    private let tabs = NSTabView()
    private let profilePicker = NSPopUpButton()
    private let displayPicker = NSPopUpButton()
    private let diagnosticText = NSTextView()
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let shortcutStatus = NSTextField(wrappingLabelWithString: "")
    private var toggleButtons: [String: NSButton] = [:]
    private var displays: [Display] = []
    private var profileButtons: [NSButton] = []
    private var monitorButtons: [NSButton] = []
    init(app: MenuBarApp) { self.app = app; super.init() }

    func show(tab: Int) {
        if window == nil { build() }
        refresh()
        tabs.selectTabViewItem(at: tab)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    private func text(_ value: String, size: CGFloat = 13, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        field.textColor = bold ? .labelColor : .secondaryLabelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func stack(_ views: [NSView], horizontal: Bool = false) -> NSStackView {
        let view = NSStackView(views: views)
        view.orientation = horizontal ? .horizontal : .vertical
        view.alignment = horizontal ? .centerY : .leading
        view.spacing = horizontal ? 10 : 14
        return view
    }
    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        if [#selector(applyProfile), #selector(renameProfile), #selector(updateProfile), #selector(deleteProfile)].contains(selector) {
            profileButtons.append(button)
        }
        if [#selector(toggleFavorite), #selector(forgetDisplay)].contains(selector) { monitorButtons.append(button) }
        return button
    }
    private func toggle(_ title: String, key: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(changeToggle(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        toggleButtons[key] = button
        return button
    }
    private func addTab(_ title: String, content: NSView) {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -22)
        ])
        let item = NSTabViewItem(identifier: title); item.label = title; item.view = container
        tabs.addTabViewItem(item)
    }
    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 710), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "HiDPI Settings"
        window.isReleasedWhenClosed = false
        window.center()
        let icon = NSImageView()
        icon.image = NSImage(named: NSImage.applicationIconName)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 54), icon.heightAnchor.constraint(equalToConstant: 54)])
        let header = stack([icon, stack([text("HiDPI", size: 23, bold: true), text("Sharper text. Your scale.", size: 13)])], horizontal: true)
        let root = stack([header, tabs])
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            tabs.widthAnchor.constraint(equalTo: root.widthAnchor),
            tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 580)
        ])
        let general = stack([
            text("Make your setup feel consistent", size: 16, bold: true),
            toggle("Restore saved modes when HiDPI starts", key: "restoreOnStartup"),
            toggle("Restore after wake or monitor reconnect", key: "restoreOnWake"),
            toggle("Pause automatic restore", key: "pauseRestore"),
            toggle("Remember mode changes made in System Settings", key: "adoptSystemSettings"),
            text("Connecting a monitor restores only that monitor, retried up to three times. Only modes you confirmed here, or chose in System Settings for a monitor HiDPI already restores, are remembered."),
            text("Launch at login", size: 14, bold: true),
            stack([button("Enable", #selector(enableLogin)), button("Disable", #selector(disableLogin)), button("Login Items…", #selector(openLoginItems))], horizontal: true),
            loginStatus,
            text("Keyboard shortcuts", size: 14, bold: true),
            toggle("Enable global shortcuts", key: "shortcutsEnabled"),
            text("⌃⌥⌘ ← / →   Previous / next favorite on the monitor under your pointer\n⌃⌥⌘ 1–9       Apply profiles in their saved order"),
            shortcutStatus,
            text("Safe switching", size: 14, bold: true),
            text("New mode and profile selections ask you to keep the settings. If you do nothing, the previous mode returns after 15 seconds."),
            button("Restore Saved Settings Now", #selector(restoreNow))
        ])
        addTab("General", content: general)
        profilePicker.target = self; profilePicker.action = #selector(profileChanged)
        profilePicker.widthAnchor.constraint(equalToConstant: 560).isActive = true
        displayPicker.widthAnchor.constraint(equalToConstant: 560).isActive = true
        addTab("Profiles & Favorites", content: stack([
            text("One setup, one click", size: 16, bold: true),
            text("Save each monitor’s resolution and refresh rate together. Try names like Work, Gaming, or Presentation."),
            profilePicker,
            stack([button("Apply", #selector(applyProfile)), button("Save New…", #selector(saveCurrentProfile)), button("Rename…", #selector(renameProfile))], horizontal: true),
            stack([button("Update from Current Setup", #selector(updateProfile)), button("Delete Profile", #selector(deleteProfile))], horizontal: true),
            text("All monitors in a profile must be connected and support their saved modes before any display changes."),
            text("Monitor favorites", size: 14, bold: true), displayPicker,
            stack([button("Favorite / Unfavorite Current", #selector(toggleFavorite)), button("Forget Saved Setting", #selector(forgetDisplay))], horizontal: true),
            text("Favorites appear in the monitor’s menu. Forget stops automatic restore for that monitor; it keeps your favorites and profiles."),
            button("Refresh Connected Monitors", #selector(refresh))
        ]))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = diagnosticText
        diagnosticText.isEditable = false; diagnosticText.isSelectable = true
        diagnosticText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticText.textContainerInset = NSSize(width: 10, height: 10)
        diagnosticText.isVerticallyResizable = true; diagnosticText.isHorizontallyResizable = false
        diagnosticText.autoresizingMask = [.width]
        diagnosticText.textContainer?.widthTracksTextView = true
        scroll.widthAnchor.constraint(equalToConstant: 560).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 365).isActive = true
        addTab("Diagnostics", content: stack([
            text("Understand your display setup", size: 16, bold: true),
            text("Current and remembered modes, rendering resolution, availability, and the last restore result."),
            scroll,
            stack([button("Refresh", #selector(refresh)), button("Copy Report", #selector(copyReport))], horizontal: true),
            text("Reports include monitor identities. You choose whether to share them.", size: 11)
        ]))
    }
    @objc func refresh() {
        guard window != nil else { return }
        for (key, button) in toggleButtons { button.state = Preferences.store.bool(key) ? .on : .off }
        let profileID = selectedProfile?.id
        profilePicker.removeAllItems()
        for profile in Preferences.store.profiles {
            profilePicker.addItem(withTitle: profile.name)
            profilePicker.lastItem?.representedObject = profile.id.uuidString
        }
        if let profileID, let index = Preferences.store.profiles.firstIndex(where: { $0.id == profileID }) { profilePicker.selectItem(at: index) }
        if profilePicker.numberOfItems == 0 { profilePicker.addItem(withTitle: "No saved profiles") }
        let displayID = selectedDisplay?.stableID
        displays = Display.online()
        displayPicker.removeAllItems()
        for (index, display) in displays.enumerated() {
            displayPicker.addItem(withTitle: "\(index + 1). \(display.name) — \(display.currentMode?.spec.label ?? "Unknown")")
        }
        if let displayID, let index = displays.firstIndex(where: { $0.stableID == displayID }) { displayPicker.selectItem(at: index) }
        if displays.isEmpty { displayPicker.addItem(withTitle: "No connected monitors") }
        profileButtons.forEach { $0.isEnabled = selectedProfile != nil }
        monitorButtons.forEach { $0.isEnabled = selectedDisplay != nil }
        diagnosticText.string = Diagnostics.report()
        shortcutStatus.stringValue = app.shortcuts.status
        refreshLoginStatus()
    }
    private var selectedProfile: DisplayProfile? {
        guard let id = profilePicker.selectedItem?.representedObject as? String else { return nil }
        return Preferences.store.profiles.first { $0.id.uuidString == id }
    }
    private var selectedDisplay: Display? {
        let index = displayPicker.indexOfSelectedItem
        return displays.indices.contains(index) ? displays[index] : nil
    }
    private func askName(title: String, initial: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title
        let input = NSTextField(string: initial); input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        input.placeholderString = "For example: Work"
        alert.accessoryView = input; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        return alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil
    }
    @objc func saveCurrentProfile() {
        guard let name = askName(title: "Save current display setup") else { return }
        do { try Preferences.store.saveProfile(name: name, displays: Preferences.capture(Display.online())); refresh() }
        catch { app.showError(error) }
    }
    @objc private func renameProfile() {
        guard let profile = selectedProfile, let name = askName(title: "Rename profile", initial: profile.name) else { return }
        do { try Preferences.store.saveProfile(name: name, displays: profile.displays, replacing: profile.id); refresh() }
        catch { app.showError(error) }
    }
    @objc private func updateProfile() {
        guard let profile = selectedProfile else { return }
        do { try Preferences.store.saveProfile(name: profile.name, displays: Preferences.capture(Display.online()), replacing: profile.id); refresh() }
        catch { app.showError(error) }
    }
    @objc private func deleteProfile() {
        guard let profile = selectedProfile else { return }
        let alert = NSAlert(); alert.messageText = "Delete \"\(profile.name)\"?"
        alert.informativeText = "Your current display settings stay as they are."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { Preferences.store.deleteProfile(id: profile.id); refresh() }
    }
    @objc private func applyProfile() { if let profile = selectedProfile { app.applyProfile(profile); refresh() } }
    @objc private func profileChanged() { profileButtons.forEach { $0.isEnabled = selectedProfile != nil } }
    @objc private func toggleFavorite() {
        guard let display = selectedDisplay, let current = display.currentMode else { return }
        Preferences.store.toggleFavorite(current.spec, id: display.stableID); refresh()
    }
    @objc private func forgetDisplay() {
        guard let display = selectedDisplay else { return }
        Preferences.forget(display); app.preferencesChanged(); refresh()
    }
    @objc private func changeToggle(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        Preferences.store.set(sender.state == .on, for: key); app.preferencesChanged(); refresh()
    }
    @objc private func restoreNow() { app.restoreNow(); refresh() }
    @objc private func copyReport() {
        refresh(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnosticText.string, forType: .string)
    }
    private func refreshLoginStatus() {
        guard #available(macOS 13.0, *), Bundle.main.bundleURL.pathExtension == "app" else {
            loginStatus.stringValue = "Launch the HiDPI.app bundle to manage login behavior."; return
        }
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus.stringValue = "Enabled"
        case .requiresApproval: loginStatus.stringValue = "Waiting for your approval in System Settings → Login Items."
        case .notRegistered: loginStatus.stringValue = "Disabled"
        case .notFound: loginStatus.stringValue = "App registration unavailable. Move HiDPI.app to Applications and try again."
        @unknown default: loginStatus.stringValue = "Unknown registration status"
        }
    }
    @objc private func enableLogin() {
        guard #available(macOS 13.0, *), Bundle.main.bundleURL.pathExtension == "app" else {
            app.showError(CLIError("launch HiDPI.app on macOS 13 or later to enable launch at login")); return
        }
        do { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }; refreshLoginStatus() }
        catch { refreshLoginStatus(); app.showError(error) }
    }
    @objc private func disableLogin() {
        guard #available(macOS 13.0, *) else { return }
        do { if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }; refreshLoginStatus() }
        catch { app.showError(error) }
    }
    @objc private func openLoginItems() {
        if #available(macOS 13.0, *) { SMAppService.openSystemSettingsLoginItems() }
    }
}
