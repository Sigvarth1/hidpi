import AppKit
import CoreGraphics
import Darwin

/// Testable transaction state machine; only Keep persists preferences.
final class SwitchTransaction {
    enum State { case ready, previewing, kept, reverted, failed }
    private(set) var state = State.ready
    private let preview: () throws -> Void
    private let commit: () throws -> Void
    private let rollback: () throws -> Void
    private let remember: () -> Void
    init(preview: @escaping () throws -> Void, commit: @escaping () throws -> Void,
         rollback: @escaping () throws -> Void, remember: @escaping () -> Void) {
        self.preview = preview; self.commit = commit; self.rollback = rollback; self.remember = remember
    }
    func begin() throws {
        guard state == .ready else { throw CLIError("a switch is already in progress") }
        do { try preview(); state = .previewing }
        catch { try recover(from: error) }
    }
    func keep() throws {
        guard state == .previewing else { throw CLIError("there is no active preview") }
        do { try commit() } catch { try recover(from: error); return }
        remember(); state = .kept
    }
    func revert() throws {
        guard state == .previewing else { return }
        do { try rollback(); state = .reverted }
        catch { state = .failed; throw error }
    }
    private func recover(from error: Error) throws {
        state = .failed
        do { try rollback() }
        catch let rollbackError { throw CLIError("\(error.localizedDescription). Revert also failed: \(rollbackError.localizedDescription)") }
        throw error
    }
}

enum SafeSwitch {
    static var isActive = false
    static let previewSeconds = 15
    /// Undoing a preview must not turn the previous mode (possibly a session-only restore) into a permanent setting.
    static let rollbackScope: CGConfigureOption = .forSession
    private static var activeTransaction: SwitchTransaction?

    /// Revert an open preview, e.g. when the app is asked to quit during logout.
    /// If this fails, the app-only preview scope still makes macOS revert when the process exits.
    @discardableResult
    static func revertActivePreview() -> Bool {
        guard let transaction = activeTransaction else { return false }
        do { try transaction.revert(); return true } catch { return false }
    }

    static func transaction(for targets: [DisplaySelection]) throws -> SwitchTransaction {
        guard !targets.isEmpty else { throw CLIError("no displays selected") }
        guard Set(targets.map { $0.display.stableID }).count == targets.count else { throw CLIError("duplicate monitor identity; switch cancelled") }
        let originals = try targets.map { target -> DisplaySelection in
            guard let mode = target.display.currentMode else { throw CLIError("cannot capture the previous mode for \(target.display.name)") }
            return DisplaySelection(display: target.display, mode: mode)
        }
        let verify = {
            for target in targets {
                guard target.display.currentMode?.spec.matches(target.mode.spec) == true else {
                    throw CLIError("\(target.display.name) did not report the requested mode")
                }
            }
        }
        return SwitchTransaction(preview: {
            // App-only scope also lets macOS revert if the previewing process exits.
            try DisplayConfiguration.apply(targets, scope: .forAppOnly)
            try verify()
        }, commit: {
            try DisplayConfiguration.apply(targets, scope: .permanently)
            try verify()
        }, rollback: {
            let online = Display.online()
            // A disconnected monitor must not prevent restoring the remaining monitors.
            var errors: [String] = []
            for original in originals {
                guard let display = online.first(where: { $0.stableID == original.display.stableID }) else { continue }
                let mode: Mode
                if display.id == original.display.id { mode = original.mode }
                else if let resolved = Mode.resolve(original.mode.spec, in: Mode.all(for: display.id)) { mode = resolved }
                else { errors.append("\(display.name): previous mode unavailable"); continue }
                do { try DisplayConfiguration.apply([DisplaySelection(display: display, mode: mode)], scope: rollbackScope) }
                catch { errors.append(error.localizedDescription) }
            }
            if !errors.isEmpty { throw CLIError(errors.joined(separator: "; ")) }
        }, remember: {
            for target in targets { Preferences.remember(target.mode, for: target.display) }
        })
    }

    @discardableResult
    static func run(_ targets: [DisplaySelection], gui: Bool, assumeYes: Bool = false) throws -> Bool {
        guard !isActive else { throw CLIError("finish the current display preview first") }
        let operationLock = try OperationLock()
        defer { withExtendedLifetime(operationLock) {} }
        isActive = true
        defer { isActive = false }
        let transaction = try transaction(for: targets)
        activeTransaction = transaction
        defer { activeTransaction = nil }
        try transaction.begin()
        let keep = assumeYes || (gui ? confirmInWindow() : confirmInTerminal())
        // A quit request during the prompt may already have reverted the preview.
        guard transaction.state == .previewing else { return false }
        if keep { try transaction.keep() } else { try transaction.revert() }
        return keep
    }

    static func confirmInWindow(timeout: TimeInterval = Double(previewSeconds)) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Keep these display settings?"
        alert.informativeText = "Your previous settings return in \(Int(ceil(timeout))) seconds."
        alert.addButton(withTitle: "Keep Settings")
        alert.addButton(withTitle: "Revert")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.window.level = .modalPanel
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var timedOut = false
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            let remaining = Int(ceil(deadline - ProcessInfo.processInfo.systemUptime))
            if remaining <= 0 {
                timedOut = true
                NSApp.abortModal()
                alert.window.orderOut(nil)
            } else { alert.informativeText = "Your previous settings return in \(remaining) seconds." }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return !timedOut && response == .alertFirstButtonReturn
    }

    private static func confirmInTerminal() -> Bool {
        guard isatty(STDIN_FILENO) == 1 else {
            print("No interactive terminal; reverting. Use --yes to explicitly keep an automated change.")
            return false
        }
        print("Keep these settings? Type y and press Return within \(previewSeconds) seconds: ", terminator: "")
        fflush(stdout)
        let deadline = ProcessInfo.processInfo.systemUptime + Double(previewSeconds)
        var input = [UInt8]()
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            let result = poll(&descriptor, 1, remaining)
            if result < 0 && errno == EINTR { continue }
            guard result > 0, descriptor.revents & Int16(POLLIN) != 0 else { return false }
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 1 else { return false }
            if byte == 10 || byte == 13 {
                return String(bytes: input, encoding: .utf8)?.trimmingCharacters(in: .whitespaces).lowercased() == "y"
            }
            input.append(byte)
            if input.count > 32 { return false }
        }
        return false
    }
}
