import AppKit
import Combine
import Foundation
import SwiftUI

struct CleanItem: Codable, Identifiable {
    let id: String
    let category: String
    let path: String
    let bytes: UInt64
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
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
}

@MainActor
final class CleanStore: ObservableObject {
    enum Phase { case idle, scanning, ready, cleaning, finished, stopped, failed }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var items: [CleanItem] = []
    @Published var selected = Set<String>()
    @Published private(set) var results: [String: String] = [:]
    @Published private(set) var resultMessages: [String: String] = [:]
    @Published private(set) var message = "Scan user app caches and logs, then choose what to move to Trash."
    @Published private(set) var progress = 0.0
    @Published private(set) var partial = false
    @Published private(set) var kept = 0
    @Published private(set) var scannedAt: Date?
    @Published private(set) var stopping = false
    private var process: Process?
    private var input: Pipe?
    private var buffer = Data()
    private var generation = UUID()
    private var requestID = ""
    private var attempted = Set<String>()

    var busy: Bool { phase == .scanning || phase == .cleaning }
    var selectedItems: [CleanItem] { items.filter { selected.contains($0.id) } }
    var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.bytes } }
    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    var moved: [CleanItem] { items.filter { results[$0.id] == "trashed" } }
    var canClean: Bool { phase == .ready && !selected.isEmpty }

    func scan() {
        guard !busy else { return }
        items = []; selected = []; results = [:]; resultMessages = [:]; attempted = []
        partial = false; kept = 0; progress = 0; scannedAt = nil; stopping = false
        guard connect() else { return }
        phase = .scanning
        message = "Checking user caches and logs…"
        send(action: "scan")
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
        message = "Stopping… completed moves will remain in Trash."
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
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mole-dashboard-cleaner")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            phase = .failed; message = "The Clean helper is missing. Rebuild Mole Dashboard."
            return false
        }
        generation = UUID()
        let epoch = generation
        let child = Process()
        child.executableURL = helper
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
        write(["action": action, "request_id": requestID, "ids": ids])
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
        case "progress":
            let total = event.total ?? 0
            progress = total > 0 ? Double(event.checked ?? 0) / Double(total) : 0
            if !stopping { message = "\(phase == .scanning ? "Checking" : "Processing") \(min((event.checked ?? 0) + 1, total)) of \(total) · \(event.message ?? "item")" }
        case "item":
            if let item = event.item { items.append(item) }
        case "scan_done":
            stopping = false; partial = event.partial ?? false; kept = event.kept ?? 0
            if event.status == "ready" {
                phase = .ready; scannedAt = Date(); progress = 1
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

struct CleanView: View {
    @EnvironmentObject private var clean: CleanStore
    @State private var expanded: Set<String> = ["caches", "logs", "reports"]
    @State private var confirm = false
    private let groups = [("caches", "App caches", "externaldrive.badge.timemachine"),
                          ("logs", "App logs", "doc.text"), ("reports", "Diagnostic reports", "waveform.path.ecg")]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Make room, with a review first.").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("User app caches, logs, and diagnostic reports. Choose exact items after scanning.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    Label("Selected items move to Trash. Empty Trash in Finder when you are ready.", systemImage: "checkmark.shield")
                        .font(.system(size: 12)).foregroundStyle(Theme.green)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(clean.phase == .idle ? "—" : Format.bytes(clean.totalBytes)).font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("\(clean.items.count) reviewable \(clean.items.count == 1 ? "item" : "items") · scan estimate").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }.padding(24).background(Theme.card, in: RoundedRectangle(cornerRadius: 18))

            HStack(spacing: 12) {
                Image(systemName: clean.busy ? "arrow.trianglehead.2.clockwise" : "info.circle").foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 5) {
                    Text(clean.message).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    if clean.busy { ProgressView(value: clean.progress).tint(Theme.green).frame(maxWidth: 550) }
                    if clean.partial { Text("Partial scan · Some folders, sizes, or checks could not be completed.").foregroundStyle(Theme.gold).font(.system(size: 11)) }
                }
                Spacer()
                if clean.busy {
                    Button(clean.stopping ? "Stopping…" : "Stop") { clean.cancel() }.disabled(clean.stopping)
                } else {
                    Button(clean.phase == .idle ? "Scan" : "Scan again") { clean.scan() }
                        .buttonStyle(CleanActionStyle(color: Theme.green))
                        .accessibilityLabel(clean.phase == .idle ? "Scan user caches and logs" : "Scan again")
                }
            }.padding(.horizontal, 6)

            if clean.items.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: clean.busy ? "magnifyingglass" : "sparkles").font(.system(size: 44, weight: .light)).foregroundStyle(Theme.gold)
                    Text(clean.busy ? "Checking each item with Mole" : "Your review starts with a scan").font(.system(size: 18, weight: .medium))
                    Text("Mole checks protected paths, known active caches, and database use. Scanning does not remove files.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(groups, id: \.0) { group in category(group.0, title: group.1, icon: group.2) }
                    }.padding(1)
                }
            }

            HStack(spacing: 14) {
                Button("Select all") { clean.selected = Set(clean.items.map(\.id)) }.disabled(clean.phase != .ready)
                Button("Deselect all") { clean.selected = [] }.disabled(clean.phase != .ready)
                Text("\(clean.selected.count) selected · \(Format.bytes(clean.selectedBytes))").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Move selected to Trash…") { confirm = true }
                    .buttonStyle(CleanActionStyle(color: Theme.gold))
                    .disabled(!clean.canClean)
            }.padding(.top, 4)
            HStack {
                Text("User folders only · administrator cleanup, developer tools, app leftovers, and emptying Trash are outside this first version.")
                Spacer()
                if clean.kept > 0 { Text("\(clean.kept) empty or kept by checks") }
            }.font(.system(size: 10)).foregroundStyle(Theme.secondary)
        }
        .alert("Move \(clean.selected.count) selected \(clean.selected.count == 1 ? "item" : "items") to Trash?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { clean.cleanSelected() }
        } message: {
            Text("\(Format.bytes(clean.selectedBytes)) estimated from the scan. Mole rechecks identity and protection rules before each move. Files in Trash still use disk space until you empty it in Finder.")
        }
    }

    private func category(_ id: String, title: String, icon: String) -> some View {
        let items = clean.items.filter { $0.category == id }
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Select \(title)", isOn: Binding(get: { !items.isEmpty && items.allSatisfy { clean.selected.contains($0.id) } }, set: { value in
                    if value { clean.selected.formUnion(items.map(\.id)) } else { clean.selected.subtract(items.map(\.id)) }
                })).labelsHidden().toggleStyle(.checkbox).disabled(clean.phase != .ready || items.isEmpty)
                Image(systemName: icon).foregroundStyle(Theme.green).frame(width: 24)
                Button { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } } label: {
                    HStack {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        Text("\(items.count)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(Format.bytes(items.reduce(0) { $0 + $1.bytes })).font(.system(size: 13, weight: .medium)).monospacedDigit()
                        Image(systemName: expanded.contains(id) ? "chevron.up" : "chevron.down").font(.system(size: 10)).padding(.leading, 10)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(expanded.contains(id) ? "Collapse" : "Expand") \(title)")
            }.padding(16)
            if expanded.contains(id) {
                ForEach(items) { item in
                    Divider().overlay(Theme.border)
                    HStack(spacing: 12) {
                        Toggle("Select \(item.name)", isOn: Binding(get: { clean.selected.contains(item.id) }, set: { value in
                            if value { clean.selected.insert(item.id) } else { clean.selected.remove(item.id) }
                        })).labelsHidden().toggleStyle(.checkbox).disabled(clean.phase != .ready)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(item.path).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                            if let message = clean.resultMessages[item.id] {
                                Text(message).font(.system(size: 10)).foregroundStyle(clean.results[item.id] == "trashed" ? Theme.green : Theme.gold)
                            } else if clean.phase == .finished {
                                Text("Not processed").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(Format.bytes(item.bytes)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondary)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "folder") }
                            .buttonStyle(.plain).help("Reveal in Finder").accessibilityLabel("Reveal \(item.name) in Finder")
                            .disabled(clean.results[item.id] == "trashed" || clean.busy)
                    }.padding(.horizontal, 18).padding(.vertical, 11)
                }
                if items.isEmpty { Text(clean.busy ? "Waiting for item checks" : "No reviewed items in this scan").font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(16) }
            }
        }.background(Theme.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
    }
}

private struct CleanActionStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(enabled ? Theme.background : Theme.secondary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(enabled ? color.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}
