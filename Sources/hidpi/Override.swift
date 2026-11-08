import Foundation

/// Legacy override cleanup. Unknown files are never selected by default.
enum Override {
    static let root = "/Library/Displays/Contents/Resources/Overrides"
    static let removedMarker = ".hidpi-removed-"
    struct Entry {
        let path: String
        let displayName: String?
        let owned: Bool
    }
    static func path(for display: Display, under root: String = root) -> String {
        "\(root)/\(display.vendorFolder)/\(display.productFile)"
    }
    static func installed(displays: [Display], root: String = root) -> [Entry] {
        let fm = FileManager.default
        guard let vendors = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var entries: [Entry] = []
        for vendor in vendors where vendor.hasPrefix("DisplayVendorID-") {
            let directory = URL(fileURLWithPath: root).appendingPathComponent(vendor)
            guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let files = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for file in files where file.hasPrefix("DisplayProductID-") && !file.contains(".hidpi-") {
                let url = directory.appendingPathComponent(file)
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink == false else { continue }
                let data = try? Data(contentsOf: url)
                let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) } as? [String: Any]
                let owned = plist?["HiDPICreatedBy"] as? String == "local.hidpi"
                entries.append(Entry(path: url.path, displayName: displays.first { path(for: $0, under: root) == url.path }?.name, owned: owned))
            }
        }
        return entries.sorted { $0.path < $1.path }
    }
    @discardableResult
    static func remove(_ entry: Entry, includeForeign: Bool = false) throws -> String {
        guard entry.owned || includeForeign else { throw CLIError("override ownership is unknown; use --include-foreign to explicitly include it") }
        let fm = FileManager.default
        let backup = entry.path + removedMarker + UUID().uuidString
        try fm.moveItem(atPath: entry.path, toPath: backup)
        do {
            if fm.fileExists(atPath: entry.path + ".hidpi-backup") {
                try fm.moveItem(atPath: entry.path + ".hidpi-backup", toPath: entry.path)
            }
        } catch {
            // Preserve the active file when restoration of a displaced file fails.
            try? fm.moveItem(atPath: backup, toPath: entry.path)
            throw error
        }
        return backup
    }
    static func undo(_ backup: String, root: String = root) throws {
        let url = URL(fileURLWithPath: backup).standardizedFileURL
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        guard url.deletingLastPathComponent().deletingLastPathComponent() == rootURL,
              url.deletingLastPathComponent().lastPathComponent.hasPrefix("DisplayVendorID-"),
              url.lastPathComponent.hasPrefix("DisplayProductID-"),
              let range = url.lastPathComponent.range(of: removedMarker),
              UUID(uuidString: String(url.lastPathComponent[range.upperBound...])) != nil,
              url.resolvingSymlinksInPath() == url else { throw CLIError("not a HiDPI cleanup backup under the override directory") }
        let originalName = String(url.lastPathComponent[..<range.lowerBound])
        let original = url.deletingLastPathComponent().appendingPathComponent(originalName)
        guard !FileManager.default.fileExists(atPath: original.path) else {
            throw CLIError("an override already exists at \(original.path); it was left untouched. Your removed file remains at \(backup)")
        }
        try FileManager.default.moveItem(at: url, to: original)
    }
}
