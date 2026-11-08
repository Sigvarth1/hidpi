import Foundation

/// Portable mode identity. Driver mode numbers are intentionally never persisted.
struct ModeSpec: Codable, Equatable, Hashable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refresh: Double

    var isHiDPI: Bool { pixelWidth > width && pixelHeight > height }
    var key: String { "\(width)x\(height)|\(pixelWidth)x\(pixelHeight)|\(String(format: "%.3f", refresh))" }
    var legacyKey: String { "\(width)x\(height)|\(pixelWidth)x\(pixelHeight)|\(Int(refresh.rounded()))" }
    var size: String { "\(width) × \(height)" }
    var hz: String { refresh > 0 ? String(format: "%.2f", refresh).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) + " Hz" : "Default refresh" }
    var label: String { "\(size) · \(isHiDPI ? "HiDPI" : "Standard") · \(hz)" }

    func matches(_ other: ModeSpec) -> Bool {
        sameGeometry(other) && abs(refresh - other.refresh) < 0.01
    }
    /// Size-only comparison; some drivers report refresh differently through each API.
    func sameGeometry(_ other: ModeSpec) -> Bool {
        width == other.width && height == other.height && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
    }

    /// Parse a desktop size such as `1920x1080`, accepting the `1920 × 1080` form this tool prints.
    static func parseSize(_ text: String) -> (width: Int, height: Int)? {
        let normalized = text.lowercased().replacingOccurrences(of: "×", with: "x").filter { !$0.isWhitespace }
        let parts = normalized.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
              (640...32768).contains(width), (480...32768).contains(height) else { return nil }
        return (width, height)
    }
}

struct DisplayProfile: Codable, Equatable {
    let id: UUID
    var name: String
    var displays: [String: ModeSpec]
}

enum ModeChoices {
    /// Preserve the current refresh rate in the simple menu whenever available.
    static func bestPerSize(_ modes: [ModeSpec], current: ModeSpec?) -> [ModeSpec] {
        let groups = Dictionary(grouping: modes, by: { "\($0.width)x\($0.height)|\($0.isHiDPI)" })
        return groups.values.compactMap { group in
            if let current, let active = group.first(where: { $0.matches(current) }) { return active }
            return group.max { $0.refresh < $1.refresh }
        }.sorted { $0.width * $0.height < $1.width * $1.height }
    }

    static func recommended(_ modes: [ModeSpec], nativeWidth: Int, nativeHeight: Int,
                            current: ModeSpec?) -> [(String, ModeSpec)] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }
        let ratio = Double(nativeWidth) / Double(nativeHeight)
        let candidates = bestPerSize(modes.filter {
            $0.isHiDPI && $0.width >= 960 && $0.height >= 540 && $0.width <= nativeWidth
                && abs(Double($0.width) / Double($0.height) - ratio) < 0.025
        }, current: current)
        let goals: [(String, Double)] = [("Larger text", 0.625), ("Balanced", 0.75), ("More space", 1)]
        var used = Set<String>()
        return goals.compactMap { label, fraction in
            guard let best = candidates.min(by: {
                abs(Double($0.width) - Double(nativeWidth) * fraction) < abs(Double($1.width) - Double(nativeWidth) * fraction)
            }), used.insert(best.key).inserted else { return nil }
            return (label, best)
        }
    }
}

struct CLIError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}
