import Darwin
import Foundation

@main
enum AnalyzeContract {
    static func send(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
    static func payload(_ path: String) -> [String: Any] {
        ["scan_status": "partial", "path": path, "total_size": 300, "total_files": 2,
         "entries": [
            ["scan_status": "complete", "name": "big", "path": path + "/big", "size": 200, "is_dir": true],
            ["scan_status": "partial", "name": "small", "path": path + "/small", "size": 100, "is_dir": false],
            ["scan_status": "unavailable", "name": "restricted", "path": path + "/restricted", "size": 0, "is_dir": true]],
         "large_files": [["name": "nested.bin", "path": path + "/big/nested.bin", "size": 100]]]
    }
    // The same test executable acts as a fixed-argument fixture helper.
    static func child(_ path: String) throws {
        let scenario = URL(fileURLWithPath: path).lastPathComponent
        if scenario == "late" {
            signal(SIGTERM, SIG_IGN)
            try send(["kind": "progress", "files": 1])
            Thread.sleep(forTimeInterval: 0.3)
        }
        if scenario == "slow" { Thread.sleep(forTimeInterval: 10) }
        if scenario == "malformed" { try FileHandle.standardOutput.write(contentsOf: Data("{broken}\n".utf8)); return }
        try send(["kind": "progress", "files": 42, "directories": 2, "bytes": 300])
        try send(["kind": "done", "result": payload(scenario == "wrong" ? "/wrong-folder" : path)])
        if scenario == "exitbad" { exit(1) }
    }

    @MainActor
    static func wait(_ store: AnalyzeStore) async throws {
        let limit = Date().addingTimeInterval(5)
        while store.busy && Date() < limit { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!store.busy, "helper did not finish")
    }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.count == 2 { try child(CommandLine.arguments[1]); return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mole-analyze-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let requested = root.appendingPathComponent("spaces ' 分析").path
        let result = try JSONDecoder().decode(AnalyzeResult.self, from: JSONSerialization.data(withJSONObject: payload(requested)))
        precondition(result.matches(requested))
        precondition(!result.matches("/different"))
        precondition(result.entries[1].sizeLabel.hasPrefix("At least"))
        precondition(result.entries[2].sizeLabel == "Unavailable")
        let tiles = AnalyzeMap.tiles(result.entries, limit: 1)
        precondition(tiles.count == 2 && tiles.last?.entry == nil)
        let rects = AnalyzeMap.layout(tiles, width: 600, height: 400)
        precondition(rects.count == 2)
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        precondition(abs(area - 240_000) < 0.001)
        for rect in rects {
            precondition(abs(rect.width * rect.height / area - rect.tile.bytes / 300) < 0.000001)
            precondition(rect.x >= 0 && rect.y >= 0 && rect.x + rect.width <= 600.001 && rect.y + rect.height <= 400.001)
        }
        precondition(AnalyzeMap.layout([], width: 600, height: 400).isEmpty)
        var invalid = payload(requested)
        invalid["entries"] = [["scan_status": "complete", "name": "escape", "path": requested + "/../escape", "size": 1, "is_dir": true]]
        let escaped = try JSONDecoder().decode(AnalyzeResult.self, from: JSONSerialization.data(withJSONObject: invalid))
        precondition(!escaped.matches(requested))
        // Scaling remains bounded and area stays proportional after grouping.
        let many = (0..<1000).map { AnalyzeEntry(scan_status: .complete, name: "item\($0)", path: "/item\($0)", size: Int64($0 + 1), is_dir: true) }
        let grouped = AnalyzeMap.tiles(many)
        precondition(grouped.count == 25 && grouped.reduce(0) { $0 + $1.bytes } == 500_500)
        let manyRects = AnalyzeMap.layout(grouped, width: 400, height: 600)
        precondition(abs(manyRects.reduce(0) { $0 + $1.width * $1.height } - 240_000) < 0.001)

        for i in manyRects.indices {
            for j in manyRects.indices where j > i {
                let a = manyRects[i], b = manyRects[j]
                let overlap = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
                    * max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
                precondition(overlap < 0.00001, "map tiles overlap")
            }
        }

        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let store = AnalyzeStore(helper: helper)
        store.scan(requested)
        try await wait(store)
        precondition(store.result?.path == requested && store.result?.scan_status == .partial)
        precondition(store.scannedAt != nil && store.files == 42)
        for scenario in ["wrong", "malformed", "exitbad"] {
            store.scan(root.appendingPathComponent(scenario).path)
            try await wait(store)
            precondition(store.result == nil && store.scannedAt == nil, "invalid response became navigable")
        }
        store.scan(root.appendingPathComponent("late").path)
        let ready = Date().addingTimeInterval(3)
        while store.files != 1 && Date() < ready { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(store.files == 1)
        store.cancel()
        try await wait(store)
        precondition(store.result == nil, "a late response restored a stopped scan")
        store.scan(root.appendingPathComponent("slow").path)
        precondition(store.busy)
        store.cancel()
        try await wait(store)
        precondition(store.result == nil && store.message.contains("stopped"))
        store.scan(requested)
        try await wait(store)
        precondition(store.result?.path == requested, "new scan could not follow cancellation")
        store.folder = root.appendingPathComponent("edited-path").path
        precondition(store.result == nil && store.scannedAt == nil, "edited path retained another folder's result")
        print("Analyze Swift contracts passed: coverage, map proportions, grouping, response binding, cancellation, restart")
    }
}
