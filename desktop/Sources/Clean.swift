import AppKit
import SwiftUI

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
