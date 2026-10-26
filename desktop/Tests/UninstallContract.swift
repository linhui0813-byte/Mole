import Foundation

@main
enum UninstallContract {
    static func send(_ value: [String: Any]) throws {
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: value) + Data([10]))
    }
    static func helper() throws {
        while let line = readLine(), let data = line.data(using: .utf8), let command = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = command["request_id"] as? String {
            switch command["action"] as? String {
            case "apps":
                try send(["kind": "app", "request_id": id, "app": ["id": "app-id", "name": "Fixture", "path": "/fixture/Fixture.app", "bundle_id": "com.fixture.app", "version": "1"]])
                try send(["kind": "scan_done", "request_id": id, "status": "ready"])
            case "app_review":
                precondition(command["app_id"] as? String == "app-id")
                for (key, category, path) in [("bundle-id", "uninstall-bundle", "/fixture/Fixture.app"), ("data-id", "uninstall-data", "/fixture/Library/Preferences/com.fixture.app.plist")] {
                    try send(["kind": "item", "request_id": id, "item": ["id": key, "category": category, "path": path, "bytes": 4096]])
                }
                Thread.sleep(forTimeInterval: 0.1)
                try send(["kind": "scan_done", "request_id": id, "status": "ready"])
            case "clean":
                precondition(Set(command["ids"] as! [String]) == ["bundle-id", "data-id"])
                precondition(command["acknowledged_items"] as? [String] == ["data-id"])
                try send(["kind": "result", "request_id": id, "item_id": "bundle-id", "status": "trashed", "message": "Fixture bundle moved"])
                try send(["kind": "result", "request_id": id, "item_id": "data-id", "status": "kept", "message": "Shared owner"])
                try send(["kind": "clean_done", "request_id": id, "status": "finished"])
            default: break
            }
        }
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(4)
        while !predicate() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "Fixture protocol timed out")
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 2 { precondition(CommandLine.arguments[1] == "--uninstall"); try helper(); return }
        let store = CleanStore(uninstall: true, helper: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL)
        store.scan()
        try await wait { store.phase == .ready }
        precondition(store.applications.count == 1 && store.items.isEmpty && !store.canClean)
        let app = store.applications[0]
        store.reviewApplication(app)
        try await wait { store.phase == .ready }
        precondition(store.selected == ["bundle-id"] && store.canClean, "Only the bundle should start selected")
        store.selected = ["data-id"]
        store.acknowledgedItems = ["data-id"]
        precondition(!store.canClean, "Data-only selection allowed uninstall")
        store.selected = ["bundle-id", "data-id"]
        store.acknowledgedItems = []
        precondition(!store.canClean, "App data lacked explicit acknowledgement")
        store.acknowledgedItems = ["data-id"]
        precondition(store.canClean)
        store.cleanSelected()
        try await wait { store.phase == .finished }
        precondition(store.moved.count == 1 && store.results["data-id"] == "kept" && store.selected.isEmpty)
        store.scan()
        try await wait { store.phase == .ready }
        precondition(store.applications.count == 1 && store.acknowledgedItems.isEmpty && store.results.isEmpty)
        store.reviewApplication(store.applications[0])
        try await wait { store.items.count == 2 }
        store.cancel()
        try await wait { store.phase == .stopped }
        precondition(!store.canClean && store.selected.isEmpty, "Late ready response authorized a cancelled review")
        store.stop()
        print("Uninstall UI contracts passed: inventory, optional data, bundle requirement, consent, outcomes, refresh, late cancellation")
    }
}
