import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class AnalyzeStore: ObservableObject {
    let actions: CleanStore
    @Published var selected = Set<String>()
    @Published private(set) var bindings: [String: AnalyzeBinding] = [:]
    @Published private(set) var result: AnalyzeResult?
    @Published private(set) var busy = false
    @Published private(set) var stopping = false
    @Published private(set) var message = "Choose a folder to see where its space is used."
    @Published private(set) var files = 0
    @Published private(set) var directories = 0
    @Published private(set) var scannedBytes: Int64 = 0
    @Published private(set) var scannedAt: Date?
    @Published var folder = NSHomeDirectory() {
        didSet {
            if !busy && !actions.busy && folder != oldValue && result?.path != folder {
                result = nil; scannedAt = nil; selected = []; bindings = [:]; actions.resetReview()
            }
        }
    }
    private var process: Process?
    private var input: Pipe?
    private var generation = UUID()
    private var watchdog: Timer?
    private var terminalEvent = false
    private let helper: URL

    init(helper: URL? = nil, actions: CleanStore? = nil) {
        self.actions = actions ?? CleanStore(analyze: true)
        self.helper = helper ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mole-dashboard-analyzer")
    }

    func scan(_ path: String? = nil, preserveActions: Bool = false) {
        guard !busy, !actions.busy else { return }
        let expanded = ((path ?? folder) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
            message = "Enter an absolute folder path, or choose a folder."; return
        }
        let requested = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if !preserveActions { actions.resetReview() }
        folder = requested; result = nil; scannedAt = nil; selected = []; bindings = [:]
        files = 0; directories = 0; scannedBytes = 0; terminalEvent = false
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            message = "The Analyze helper is missing. Rebuild Mole Dashboard."; return
        }
        generation = UUID()
        let epoch = generation
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = helper; child.arguments = [requested]
        child.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "MOLE_TEST_NO_AUTH": "1"]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        do { try child.run() }
        catch { message = "Cannot start Analyze: \(error.localizedDescription)"; return }
        process = child; input = stdin; busy = true; stopping = false
        message = "Measuring this folder… larger folders may take longer."
        watchdog = Timer.scheduledTimer(withTimeInterval: 130, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == epoch, self.busy else { return }
                self.cancel()
                self.message = "The scan timed out. Choose a smaller folder and scan again."
            }
        }
        // Read on a worker; serial main-queue delivery keeps the final event
        // ordered before process completion. Each request has its own identity.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let handle = stdout.fileHandleForReading
            defer { try? handle.close() }
            var buffer = Data(), invalid = false
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                if buffer.count > 32_000_000 { invalid = true; child.terminate(); break }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    do {
                        let event = try JSONDecoder().decode(AnalyzeEvent.self, from: line)
                        DispatchQueue.main.async {
                            guard let self, self.generation == epoch else { return }
                            self.accept(event, requested: requested)
                        }
                    } catch { invalid = true; child.terminate(); break }
                }
                if invalid { break }
            }
            // Closing a rejected stream also releases a writer blocked on its pipe.
            try? handle.close()
            child.waitUntilExit()
            let malformed = invalid || !buffer.isEmpty
            DispatchQueue.main.async {
                guard let self, self.generation == epoch else { return }
                self.watchdog?.invalidate(); self.watchdog = nil
                self.input?.fileHandleForWriting.closeFile(); self.input = nil; self.process = nil
                self.busy = false
                if self.stopping {
                    self.result = nil; self.scannedAt = nil
                    if !self.message.contains("timed out") { self.message = "Scan stopped. Choose a folder and scan again." }
                } else if malformed || !self.terminalEvent || (child.terminationStatus != 0 && self.result != nil) {
                    self.result = nil; self.scannedAt = nil
                    self.message = "Analyze stopped without a complete response. Scan again or choose a smaller folder."
                }
                self.stopping = false
            }
        }
    }

    private func accept(_ event: AnalyzeEvent, requested: String) {
        guard busy, !stopping, !terminalEvent else { return }
        switch event.kind {
        case "progress":
            files = max(0, event.files ?? 0); directories = max(0, event.directories ?? 0)
            scannedBytes = max(0, event.bytes ?? 0)
        case "done":
            terminalEvent = true
            guard let snapshot = event.result, snapshot.matches(requested) else {
                message = "The scan returned an invalid folder result. Scan again."; return
            }
            let paths = Set(snapshot.entries.filter { $0.scan_status != .unavailable && !$0.isLink }.map(\.path) + (snapshot.large_files ?? []).map(\.path))
            bindings = (event.bindings ?? [:]).filter { key, value in paths.contains(key) && value.path == key }
            result = snapshot; scannedAt = Date()
            switch snapshot.scan_status {
            case .complete: message = "Scan finished within Mole’s scan filters. Sizes are estimates from a changing disk."
            case .partial: message = "Partial scan. Some content could not be measured; shown sizes may be lower bounds."
            case .unavailable: message = "Size unavailable. This folder could not be measured."
            }
        case "error":
            terminalEvent = true; message = event.message ?? "This folder could not be measured."
        default:
            terminalEvent = true; message = "The Analyze response is unsupported. Rebuild Mole Dashboard."
        }
    }

    func cancel() {
        guard busy, !stopping else { return }
        stopping = true; result = nil; scannedAt = nil; message = "Stopping the scan…"
        input?.fileHandleForWriting.closeFile(); input = nil
        guard let child = process else { return }
        child.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    func reviewSelection() {
        guard !busy, !actions.busy, !selected.isEmpty else { return }
        actions.review(selected.sorted().compactMap { bindings[$0] })
    }

    func stop() { cancel(); actions.stop() }

    func chooseFolder() {
        guard !busy, !actions.busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to analyze"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url { scan(url.path) }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
