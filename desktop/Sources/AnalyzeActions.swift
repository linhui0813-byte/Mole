import AppKit
import SwiftUI

struct AnalyzeReviewSheet: View {
    @ObservedObject var actions: CleanStore
    let close: () -> Void
    private var noEligibleItems: Bool { actions.phase == .ready && actions.items.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(actions.phase == .finished ? "Trash results" : "Review items for Trash", systemImage: "trash")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                Text(noEligibleItems ? "Nothing eligible" : actions.phase == .finished ? "\(Format.bytes(actions.moved.reduce(0) { $0 + $1.bytes })) moved" : Format.bytes(actions.selectedBytes))
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Text("Review each exact path. Moving a folder includes its contents. Files stay in Trash until you empty it in Finder.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Text("Review sizes are fresh allocated-size estimates and may differ from the map.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            HStack {
                if actions.busy { ProgressView().controlSize(.small) }
                Text(actions.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if actions.busy { ProgressView(value: actions.progress).tint(Theme.green) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(actions.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            if actions.phase == .ready {
                                Toggle("Move \(item.name)", isOn: Binding(get: { actions.selected.contains(item.id) }, set: { value in
                                    if value { actions.selected.insert(item.id) } else { actions.selected.remove(item.id) }
                                })).labelsHidden().toggleStyle(.checkbox)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.name).font(.system(size: 13, weight: .semibold))
                                Text(item.path).font(.system(size: 11)).foregroundStyle(Theme.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                if item.requiresAcknowledgement {
                                    Label(item.isWholeProject ? "Whole Git project" : "Whole folder", systemImage: "exclamationmark.triangle")
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.gold)
                                    Text("Includes every file and subfolder, including Git history, uncommitted work, built apps, databases, and local settings such as .env files. Save your work and close apps and tools using this folder first. Links move as links; targets outside this folder stay in place.")
                                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                                    if actions.phase == .ready {
                                        Toggle("I saved my work, closed its apps and tools, and want to move this entire folder to Trash", isOn: Binding(get: { actions.acknowledgedItems.contains(item.id) }, set: { value in
                                            if value { actions.acknowledgedItems.insert(item.id) } else { actions.acknowledgedItems.remove(item.id) }
                                        })).toggleStyle(.checkbox).font(.system(size: 12))
                                    }
                                }
                                if let result = actions.resultMessages[item.id] {
                                    Text(result).font(.system(size: 11)).foregroundStyle(actions.results[item.id] == "trashed" ? Theme.green : Theme.gold)
                                } else if actions.phase == .finished {
                                    Text("Not moved").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                }
                            }
                            Spacer()
                            Text(Format.bytes(item.bytes)).font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
                        }.padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(actions.refusals.keys.sorted(), id: \.self) { path in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Label(actions.coveredPaths.contains(path) ? "Covered by parent review" : "Kept", systemImage: actions.coveredPaths.contains(path) ? "folder" : "lock.shield")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.gold)
                                Spacer()
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }.font(.system(size: 11))
                            }
                            Text(path).font(.system(size: 11)).foregroundStyle(Theme.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text(actions.refusals[path] ?? "").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if actions.items.isEmpty && actions.refusals.isEmpty {
                        Text(actions.busy ? "Checking identities, protected contents, and current sizes…" : "No items are authorized for a Trash move.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(24)
                    }
                }
            }
            HStack {
                if actions.busy {
                    Button(actions.stopping ? "Stopping…" : "Stop") { actions.cancel() }.disabled(actions.stopping)
                } else {
                    Button(actions.phase == .ready && !noEligibleItems ? "Cancel" : "Done") {
                        if actions.phase == .ready { actions.resetReview() }
                        close()
                    }.keyboardShortcut(.cancelAction)
                }
                Spacer()
                if actions.phase == .ready && !noEligibleItems {
                    Text("\(actions.selected.count) checked · \(Format.bytes(actions.selectedBytes)) estimated")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Button("Move checked items to Trash") { actions.cleanSelected() }
                        .buttonStyle(.borderedProminent).tint(Theme.gold).foregroundStyle(actions.canClean ? Theme.background : Theme.secondary).disabled(!actions.canClean)
                }
            }
        }.padding(24).frame(width: 740, height: 580).background(Theme.background).foregroundStyle(Theme.text).preferredColorScheme(.dark)
            .onDisappear { if actions.phase == .ready { actions.resetReview() } }
    }
}
