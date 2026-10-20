import Foundation

@main
enum AnalyzeActionsContract {
    static func send(_ object: [String: Any]) throws {
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
    }
    static func helper() throws {
        while let line = readLine(), let data = line.data(using: .utf8), let command = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = command["request_id"] as? String {
            let action = command["action"] as? String
            if action == "review" {
                let values = command["candidates"] as! [[String: Any]]
                let path = values[0]["path"] as! String
                try send(["kind": "item", "request_id": id, "item": ["id": "reviewed-id", "category": "analyze", "path": path, "bytes": 4096]])
                if path.contains("slow") { Thread.sleep(forTimeInterval: 0.25) }
                try send(["kind": "refused", "request_id": id, "path": "/fixture/protected", "message": "Kept: protected fixture"])
                try send(["kind": "refused", "request_id": id, "path": "/fixture/covered-child", "status": "covered", "message": "Included with reviewed parent"])
                try send(["kind": "scan_done", "request_id": id, "status": "ready", "kept": 1])
            } else if action == "clean" {
                precondition(command["ids"] as? [String] == ["reviewed-id"], "UI sent an unreviewed identity")
                try send(["kind": "result", "request_id": id, "item_id": "reviewed-id", "status": "trashed", "message": "Simulated fixture outcome"])
                try send(["kind": "clean_done", "request_id": id, "status": "finished"])
            }
        }
    }
    @MainActor
    static func wait(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(4)
        while !predicate() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "timed out waiting for the fixture protocol")
    }
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.count == 2 { precondition(CommandLine.arguments[1] == "--analyze-actions"); try helper(); return }
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let store = CleanStore(analyze: true, helper: helper)
        func candidate(_ path: String) -> AnalyzeBinding {
            AnalyzeBinding(path: path, identity: "1:2:3", parent: "/fixture", parent_id: "1:1", target_id: "1:2", stamp: "fixture")
        }
        store.review([candidate("/fixture/selected")])
        try await wait { store.phase == .ready }
        precondition(store.items.count == 1 && store.selected == ["reviewed-id"] && store.canClean)
        precondition(store.refusals["/fixture/protected"] != nil)
        precondition(store.coveredPaths == ["/fixture/covered-child"])
        store.selected = []
        precondition(!store.canClean, "empty selection enabled execution")
        store.selected = ["reviewed-id"]
        store.cleanSelected()
        try await wait { store.phase == .finished }
        precondition(store.moved.count == 1 && !store.canClean && store.selected.isEmpty)
        store.review([candidate("/fixture/slow")])
        try await wait { store.items.count == 1 }
        store.cancel()
        try await wait { store.phase == .stopped }
        precondition(store.selected.isEmpty && !store.canClean, "late review response reauthorized a stopped plan")
        store.review([candidate("/fixture/new-selection")])
        try await wait { store.phase == .ready }
        precondition(store.items[0].path == "/fixture/new-selection")
        store.resetReview()
        precondition(store.phase == .idle && !store.canClean && store.items.isEmpty && store.coveredPaths.isEmpty)
        print("Analyze action UI contracts passed: reviewed IDs, refusal details, outcomes, late-cancel rejection, restart, reset")
    }
}
