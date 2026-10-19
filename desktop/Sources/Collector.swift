import AppKit
import Combine
import Foundation

@MainActor
final class DashboardStore: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var status = "Connecting to your Mac"
    @Published var paused = false
    @Published var error: String?
    @Published var receivedAt: Date?
    @Published var cpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var gpuHistory: [Double] = []
    @Published var downloadHistory: [Double] = []
    @Published var uploadHistory: [Double] = []
    private var process: Process?
    private var generation = UUID()
    private var watchdog: Timer?
    private let iconCache = NSCache<NSString, NSImage>()
    private var startedAt = Date()

    var stale: Bool { receivedAt.map { Date().timeIntervalSince($0) > 12 } ?? false }
    var live: Bool { process != nil && !paused && !stale && error == nil && receivedAt != nil && snapshot?.collection_error == nil }

    func start() {
        guard process == nil else { return }
        generation = UUID()
        let runID = generation
        paused = false
        error = nil
        status = "Connecting to your Mac"
        startedAt = Date()
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mole-dashboard-collector")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            error = "The bundled collector is missing. Rebuild this app with desktop/build.sh."
            status = "Collector missing"
            return
        }
        let child = Process()
        child.executableURL = helper
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                             "LC_ALL": "C", "MOLE_TEST_NO_AUTH": "1"]
        let output = Pipe()
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, self.generation == runID else { return }
                self.process = nil
                self.error = "The collector stopped (status \(child.terminationStatus)). Press Reconnect to try again."
                self.status = "Disconnected"
            }
        }
        do {
            try child.run()
            process = child
            // A blocking read loop runs off the UI thread and carries each complete
            // NDJSON record back to the main actor. No shell is involved.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let handle = output.fileHandleForReading
                defer { try? handle.close() }
                var buffer = Data()
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        do {
                            let frame = try JSONDecoder().decode(Snapshot.self, from: line)
                            Task { @MainActor in
                                guard let self, self.generation == runID else { return }
                                self.accept(frame)
                            }
                        } catch {
                            Task { @MainActor in
                                guard let self, self.generation == runID else { return }
                                self.error = "The collector sent an unreadable reading. Press Reconnect to try again."
                            }
                        }
                    }
                    if buffer.count > 16_000_000 {
                        child.terminate()
                        break
                    }
                }
            }
            watchdog?.invalidate()
            watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.process != nil else { return }
                    if self.stale || (self.receivedAt == nil && Date().timeIntervalSince(self.startedAt) > 20) {
                        self.status = "Waiting for readings"
                        self.objectWillChange.send()
                    }
                }
            }
        } catch {
            self.error = "Could not start the collector: \(error.localizedDescription)"
            status = "Disconnected"
        }
    }

    private func accept(_ frame: Snapshot) {
        snapshot = frame
        receivedAt = Date()
        error = nil
        status = frame.collection_error != nil ? "Partial reading · some data unavailable" :
            frame.enriched ? "Live · every 2 seconds" : "Reading hardware details"
        append(frame.cpu.usage, to: &cpuHistory)
        append(frame.memory.used_percent, to: &memoryHistory)
        if let gpu = frame.primaryGPU, gpu.usage >= 0 { append(gpu.usage, to: &gpuHistory) }
        append(frame.download, to: &downloadHistory)
        append(frame.upload, to: &uploadHistory)
    }

    private func append(_ value: Double, to history: inout [Double]) {
        guard value.isFinite else { return }
        history.append(value)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }

    func stop(pausing: Bool = false) {
        generation = UUID()
        watchdog?.invalidate()
        watchdog = nil
        let child = process
        process = nil
        paused = pausing
        child?.terminate()
        if pausing { status = "Paused · last readings shown" }
    }

    func togglePause() {
        if paused { reconnect() } else { stop(pausing: true) }
    }

    func reconnect() {
        stop()
        receivedAt = nil
        cpuHistory = []; memoryHistory = []; gpuHistory = []
        downloadHistory = []; uploadHistory = []
        start()
    }

    func icon(for row: RunningProcess) -> NSImage {
        let key = (row.appPath ?? row.command) as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let image: NSImage
        if let path = row.appPath {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if let running = NSRunningApplication(processIdentifier: pid_t(row.pid)), let icon = running.icon {
            image = icon
        } else {
            image = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "Process")!
        }
        iconCache.setObject(image, forKey: key)
        return image
    }
}
