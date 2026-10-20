import Foundation

enum AnalyzeCoverage: String, Decodable {
    case complete, partial, unavailable
    var label: String {
        switch self {
        case .complete: return "Measured"
        case .partial: return "Partial"
        case .unavailable: return "Unavailable"
        }
    }
}

struct AnalyzeEntry: Decodable, Identifiable {
    let scan_status: AnalyzeCoverage
    let name: String
    let path: String
    let size: Int64
    let is_dir: Bool
    var id: String { path }
    var isLink: Bool { name.hasSuffix(" →") }
    var browsable: Bool { is_dir && !isLink }
    var sizeLabel: String {
        guard size >= 0, scan_status != .unavailable else { return "Unavailable" }
        return (scan_status == .partial ? "At least " : "") + Format.bytes(UInt64(size))
    }
}

struct AnalyzeFile: Decodable, Identifiable {
    let name: String
    let path: String
    let size: Int64
    var id: String { path }
}

struct AnalyzeResult: Decodable {
    let scan_status: AnalyzeCoverage
    let path: String
    let entries: [AnalyzeEntry]
    let large_files: [AnalyzeFile]?
    let total_size: Int64
    let total_files: Int?
    func matches(_ requested: String) -> Bool {
        // Reject mismatched, repeated, or out-of-root records before navigation.
        let root = URL(fileURLWithPath: requested).standardizedFileURL.path
        guard path == root, total_size >= 0, Set(entries.map(\.path)).count == entries.count else { return false }
        let validEntry = entries.allSatisfy {
            $0.path.hasPrefix("/") && $0.path == URL(fileURLWithPath: $0.path).standardizedFileURL.path
                && URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == root
                && $0.size >= -1
        }
        let prefix = root == "/" ? "/" : root + "/"
        let validFiles = (large_files ?? []).allSatisfy {
            $0.path.hasPrefix(prefix) && URL(fileURLWithPath: $0.path).standardizedFileURL.path == $0.path && $0.size >= 0
        }
        return validEntry && validFiles
    }
}

struct AnalyzeBinding: Codable {
    let path: String
    let identity: String
    let parent: String
    let parent_id: String
    let target_id: String
    let stamp: String
}

struct AnalyzeEvent: Decodable {
    let bindings: [String: AnalyzeBinding]?
    let kind: String
    let files: Int?
    let directories: Int?
    let bytes: Int64?
    let result: AnalyzeResult?
    let message: String?
}

struct AnalyzeMapTile: Identifiable {
    let id: String
    let name: String
    let bytes: Double
    let entry: AnalyzeEntry?
}

struct AnalyzeMapRect {
    let tile: AnalyzeMapTile
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum AnalyzeMap {
    static func tiles(_ entries: [AnalyzeEntry], limit: Int = 24) -> [AnalyzeMapTile] {
        let positive = entries.filter { $0.size > 0 && $0.scan_status != .unavailable }
            .sorted { $0.size == $1.size ? $0.path < $1.path : $0.size > $1.size }
        var tiles = positive.prefix(limit).map { AnalyzeMapTile(id: $0.path, name: $0.name, bytes: Double($0.size), entry: $0) }
        let remaining = positive.dropFirst(limit)
        if !remaining.isEmpty {
            tiles.append(AnalyzeMapTile(id: "other", name: "\(remaining.count) more items", bytes: remaining.reduce(0) { $0 + Double($1.size) }, entry: nil))
        }
        return tiles
    }

    // Balanced weighted splits preserve area ratios without creating thousands
    // of tiny interactive views. Unknown and zero sizes never get invented area.
    static func layout(_ tiles: [AnalyzeMapTile], width: Double, height: Double) -> [AnalyzeMapRect] {
        guard width > 0, height > 0, !tiles.isEmpty else { return [] }
        func split(_ items: ArraySlice<AnalyzeMapTile>, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [AnalyzeMapRect] {
            if items.count == 1 { return [AnalyzeMapRect(tile: items.first!, x: x, y: y, width: w, height: h)] }
            let total = items.reduce(0) { $0 + $1.bytes }
            guard total > 0 else { return [] }
            var index = items.startIndex + 1
            var first = items.first!.bytes
            while index < items.endIndex - 1 && abs(first + items[index].bytes - total / 2) < abs(first - total / 2) {
                first += items[index].bytes; index += 1
            }
            let ratio = first / total
            let left = items[..<index], right = items[index...]
            if w >= h {
                return split(left, x, y, w * ratio, h) + split(right, x + w * ratio, y, w * (1 - ratio), h)
            }
            return split(left, x, y, w, h * ratio) + split(right, x, y + h * ratio, w, h * (1 - ratio))
        }
        return split(tiles[...], 0, 0, width, height)
    }
}
