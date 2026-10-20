import Foundation

@main
enum AnalyzeActionsContract {
    static func send(_ object: [String: Any]) throws {
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
    }
    static func helper() throws {
        var project = false
        while let line = readLine(), let data = line.data(using: .utf8), let command = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = command["request_id"] as? String {
            let action = command["action"] as? String
            if action == "review" {
                let values = command["candidates"] as! [[String: Any]]
                let path = values[0]["path"] as! String
                project = path.contains("project")
                if path.contains("blocked") {
                    try send(["kind": "refused", "request_id": id, "path": path, "message": "Browser profile is kept"])
                    try send(["kind": "scan_done", "request_id": id, "status": "ready", "kept": 1,
                              "message": "None of the selected items passed the safety checks. Nothing was moved."])
                    continue
                }
                try send(["kind": "item", "request_id": id, "item": ["id": "reviewed-id", "category": path.contains("project") ? "analyze-project" : "analyze", "path": path, "bytes": 4096]])
                if path.contains("slow") { Thread.sleep(forTimeInterval: 0.25) }
                try send(["kind": "refused", "request_id": id, "path": "/fixture/protected", "message": "Kept: protected fixture"])
                try send(["kind": "refused", "request_id": id, "path": "/fixture/covered-child", "status": "covered", "message": "Included with reviewed parent"])
                try send(["kind": "scan_done", "request_id": id, "status": "ready", "kept": 1])
            } else if action == "clean" {
                precondition(command["ids"] as? [String] == ["reviewed-id"], "UI sent an unreviewed identity")
                precondition(command["acknowledged_projects"] as? [String] == (project ? ["reviewed-id"] : []), "UI did not send the reviewed project acknowledgement")
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
        store.review([candidate("/fixture/blocked")])
        try await wait { store.phase == .ready }
        precondition(store.items.isEmpty && store.selected.isEmpty && !store.canClean)
        precondition(store.refusals.count == 1 && store.message.contains("Nothing was moved"))
        store.resetReview()
        store.review([candidate("/fixture/project")])
        try await wait { store.phase == .ready }
        precondition(store.items[0].isWholeProject && !store.canClean, "whole project did not require acknowledgement")
        store.acknowledgedProjects = ["unreviewed-id"]
        precondition(!store.canClean, "acknowledgement authorized another item")
        store.acknowledgedProjects = ["reviewed-id"]
        precondition(store.canClean)
        store.cleanSelected()
        try await wait { store.phase == .finished }
        precondition(store.moved.count == 1)
        store.resetReview()
        precondition(store.acknowledgedProjects.isEmpty, "new review retained earlier consent")
        print("Analyze action UI contracts passed: reviewed IDs, refusal details, outcomes, late-cancel rejection, restart, reset")
    }
}
