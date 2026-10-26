import AppKit
import Combine
import Foundation

struct CleanItem: Codable, Identifiable {
    let id: String
    let category: String
    let path: String
    let bytes: UInt64
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var isWholeProject: Bool { category == "analyze-project" }
    var isLibraryFolder: Bool { category == "analyze-library-folder" }
    var requiresAcknowledgement: Bool { isWholeProject || isLibraryFolder || category == "analyze-folder" || category == "uninstall-data" }
}

struct InstalledApplication: Decodable, Identifiable {
    let id: String
    let path: String
    let name: String
    let bundle_id: String
    let version: String
    let reason: String?
}

struct CleanEvent: Decodable {
    let kind: String
    let request_id: String
    let item: CleanItem?
    let item_id: String?
    let status: String?
    let message: String?
    let checked: Int?
    let total: Int?
    let kept: Int?
    let partial: Bool?
    let path: String?
    let app: InstalledApplication?
}

@MainActor
final class CleanStore: ObservableObject {
    enum Phase { case idle, scanning, ready, cleaning, finished, stopped, failed }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var items: [CleanItem] = []
    @Published private(set) var applications: [InstalledApplication] = []
    @Published var selected = Set<String>()
    @Published var acknowledgedItems = Set<String>()
    @Published private(set) var results: [String: String] = [:]
    @Published private(set) var resultMessages: [String: String] = [:]
    @Published private(set) var message = "Scan user app caches and logs, then choose what to move to Trash."
    @Published private(set) var progress = 0.0
    @Published private(set) var partial = false
    @Published private(set) var kept = 0
    @Published private(set) var refusals: [String: String] = [:]
    @Published private(set) var coveredPaths = Set<String>()
    @Published private(set) var scannedAt: Date?
    @Published private(set) var stopping = false
    private var process: Process?
    private var input: Pipe?
    private var buffer = Data()
    private var generation = UUID()
    private var requestID = ""
    private var attempted = Set<String>()
    private let analyzeMode: Bool
    let uninstallMode: Bool
    private let helperOverride: URL?

    init(analyze: Bool = false, uninstall: Bool = false, helper: URL? = nil) {
        analyzeMode = analyze; uninstallMode = uninstall; helperOverride = helper
    }

    func reviewApplication(_ app: InstalledApplication) {
        guard uninstallMode, !busy else { return }
        items = []; selected = []; acknowledgedItems = []; results = [:]; resultMessages = [:]
        refusals = [:]; attempted = []; progress = 0; stopping = false; partial = false
        guard connect() else { return }
        phase = .scanning; message = "Checking the app and its exact associated paths…"
        requestID = UUID().uuidString
        write(["action": "app_review", "request_id": requestID, "app_id": app.id])
    }

    func resetReview() {
        guard !busy else { return }
        generation = UUID()
        input?.fileHandleForWriting.closeFile(); input = nil; process = nil
        phase = .idle; items = []; selected = []; results = [:]; resultMessages = [:]; refusals = [:]; coveredPaths = []; attempted = []
        acknowledgedItems = []
        partial = false; kept = 0; progress = 0; scannedAt = nil; stopping = false
    }

    func review(_ candidates: [AnalyzeBinding]) {
        guard analyzeMode, !busy else { return }
        resetReview()
        guard connect() else { return }
        phase = .scanning; message = "Checking selected items and their contents…"
        requestID = UUID().uuidString
        guard let data = try? JSONEncoder().encode(candidates), let values = try? JSONSerialization.jsonObject(with: data) else {
            phase = .failed; message = "This selection could not be encoded. Scan again."; return
        }
        write(["action": "review", "request_id": requestID, "candidates": values])
    }

    var busy: Bool { phase == .scanning || phase == .cleaning }
    var selectedItems: [CleanItem] { items.filter { selected.contains($0.id) } }
    var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    var moved: [CleanItem] { items.filter { results[$0.id] == "trashed" } }
    var canClean: Bool { phase == .ready && !selected.isEmpty &&
        (!uninstallMode || selectedItems.contains { $0.category == "uninstall-bundle" }) &&
        selectedItems.allSatisfy { !$0.requiresAcknowledgement || acknowledgedItems.contains($0.id) } }

    func scan() {
        guard !analyzeMode, !busy else { return }
        items = []; selected = []; results = [:]; resultMessages = [:]; attempted = []
        refusals = [:]
        if uninstallMode { applications = [] }
        acknowledgedItems = []
        partial = false; kept = 0; progress = 0; scannedAt = nil; stopping = false
        guard connect() else { return }
        phase = .scanning
        message = uninstallMode ? "Finding installed apps…" : "Checking user caches and logs…"
        send(action: uninstallMode ? "apps" : "scan")
    }

    func cleanSelected() {
        guard canClean else { return }
        attempted = selected
        phase = .cleaning; progress = 0; stopping = false
        message = "Rechecking selected items before each Trash move…"
        send(action: "clean", ids: items.filter { selected.contains($0.id) }.map(\.id))
    }

    func cancel() {
        guard busy, !stopping else { return }
        stopping = true
        message = phase == .scanning ? "Stopping the review…" : "Stopping… completed moves will remain in Trash."
        write(["action": "cancel", "request_id": requestID])
    }

    func stop() {
        if busy { cancel() }
        input?.fileHandleForWriting.closeFile()
        input = nil
        // EOF requests cancellation and lets the helper reap its subprocess.
        process = nil
    }

    private func connect() -> Bool {
        if process?.isRunning == true { return true }
        let helper = helperOverride ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mole-dashboard-cleaner")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            phase = .failed; message = "The Clean helper is missing. Rebuild Mole Dashboard."
            return false
        }
        generation = UUID()
        let epoch = generation
        let child = Process()
        child.executableURL = helper
        if analyzeMode { child.arguments = ["--analyze-actions"] }
        if uninstallMode { child.arguments = ["--uninstall"] }
        child.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        if let deno = ProcessInfo.processInfo.environment["DENO_DIR"] { child.environment?["DENO_DIR"] = deno }
        let stdin = Pipe(), stdout = Pipe()
        child.standardInput = stdin; child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        buffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                self.receive(data)
            }
        }
        child.terminationHandler = { [weak self] _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                self.process = nil; self.input = nil
                if self.busy {
                    self.phase = .failed
                    self.message = "Clean stopped unexpectedly. Check the selected items and Trash, then scan again."
                }
            }
        }
        do { try child.run(); process = child; input = stdin; return true }
        catch { phase = .failed; message = "Cannot start Clean: \(error.localizedDescription)"; return false }
    }

    private func send(action: String, ids: [String] = []) {
        requestID = UUID().uuidString
        write(["action": action, "request_id": requestID, "ids": ids,
               "acknowledged_items": items.filter { selected.contains($0.id) && $0.requiresAcknowledgement && acknowledgedItems.contains($0.id) }.map(\.id)])
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let input else { return }
        do { try input.fileHandleForWriting.write(contentsOf: data + Data([10])) }
        catch { phase = .failed; message = "Clean connection closed. Scan again." }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 2_000_000 else { stop(); phase = .failed; message = "Invalid Clean response. Scan again."; return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let event = try? JSONDecoder().decode(CleanEvent.self, from: line), event.request_id == requestID else { continue }
            apply(event)
        }
    }

    private func apply(_ event: CleanEvent) {
        switch event.kind {
        case "app":
            if let app = event.app { applications.append(app) }
        case "progress":
            let total = event.total ?? 0
            progress = total > 0 ? Double(event.checked ?? 0) / Double(total) : 0
            if !stopping {
                message = total > 0 ? "\(phase == .scanning ? "Checking" : "Processing") \(min((event.checked ?? 0) + 1, total)) of \(total) · \(event.message ?? "item")" : "Checking \(event.message ?? "apps")…"
            }
        case "item":
            if let item = event.item { items.append(item) }
        case "refused":
            if let path = event.path { refusals[path] = event.message ?? "Kept by protection checks." }
            if event.status == "covered", let path = event.path { coveredPaths.insert(path) }
        case "scan_done":
            let wasStopping = stopping
            stopping = false; partial = event.partial ?? false; kept = event.kept ?? 0
            if event.status == "ready" && !wasStopping {
                phase = .ready; scannedAt = Date(); progress = 1
                if analyzeMode { selected = Set(items.map(\.id)) }
                if uninstallMode { selected = Set(items.filter { $0.category == "uninstall-bundle" }.map(\.id)) }
                message = items.isEmpty ? "No items passed the scan checks in these folders." : "Scan complete. Review the items and select what to move to Trash."
                if let note = event.message, !note.isEmpty { message = note }
            } else {
                phase = .stopped; selected = []
                message = event.message ?? "Scan stopped. Scan again before cleaning."
            }
        case "result":
            if let id = event.item_id { results[id] = event.status; resultMessages[id] = event.message }
        case "clean_done":
            phase = .finished; stopping = false; progress = 1
            let unprocessed = attempted.count - results.count
            message = "\(moved.count) moved to Trash · \(results.values.filter { $0 != "trashed" }.count) kept or unverified · \(unprocessed) not processed. Scan again to continue."
            selected = []
        case "error":
            phase = .failed; stopping = false; selected = []
            message = event.message ?? "Clean could not complete. Scan again."
        default: break
        }
    }
}
