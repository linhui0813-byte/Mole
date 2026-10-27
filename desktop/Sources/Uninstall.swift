import AppKit
import SwiftUI

struct UninstallView: View {
    @ObservedObject var store: CleanStore
    @State private var query = ""
    @State private var sort = ApplicationSort.name
    @State private var chosen: InstalledApplication?
    @State private var review: InstalledApplication?

    private var visible: [InstalledApplication] {
        store.applications.filter { query.isEmpty || "\($0.name) \($0.bundle_id) \($0.path)".localizedCaseInsensitiveContains(query) }
            .sorted(by: sort.precedes)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Uninstall apps, with their files in view.").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Review an app and its associated data. Nothing moves until you confirm.")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Text("\(store.applications.count)").font(.system(size: 36, weight: .semibold, design: .rounded))
                Text("apps").foregroundStyle(Theme.secondary)
            }.padding(24).background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 12) {
                TextField("Search apps, bundle IDs, or paths", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                Spacer()
                Picker("Sort", selection: $sort) {
                    ForEach(ApplicationSort.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 215).accessibilityLabel("Sort apps")
                if store.busy && review == nil {
                    ProgressView().controlSize(.small)
                    Button(store.stopping ? "Stopping…" : "Stop") { store.cancel() }.disabled(store.stopping)
                } else {
                    Button(store.applications.isEmpty ? "Find apps" : "Refresh apps") { chosen = nil; store.scan() }.disabled(store.busy)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("App").frame(maxWidth: .infinity, alignment: .leading)
                        Text("App size").frame(width: 85, alignment: .trailing)
                            .help("Allocated size of the app bundle. Associated data is measured separately during review.")
                        Text("Last active").frame(width: 125, alignment: .trailing)
                            .help("Last-used date recorded by macOS. It can be delayed or unavailable.")
                        Color.clear.frame(width: 16, height: 1)
                    }.font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.horizontal, 20).padding(.vertical, 12)
                    Divider()
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visible) { app in
                            Button { chosen = app } label: {
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 34, height: 34)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Text(app.version.isEmpty ? app.bundle_id : "\(app.version) · \(app.bundle_id)")
                                            .font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(app.sizeText).font(.system(size: 12)).monospacedDigit()
                                        .frame(width: 85, alignment: .trailing)
                                    Text(app.lastActiveText).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                        .frame(width: 125, alignment: .trailing)
                                    Image(systemName: "lock.shield").foregroundStyle(Theme.gold)
                                        .frame(width: 16).opacity(app.reason == nil ? 0 : 1)
                                }.padding(12).contentShape(Rectangle())
                                    .background(chosen?.id == app.id ? Theme.green.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).disabled(store.busy)
                        }
                        if visible.isEmpty {
                            Text(store.busy ? "Finding apps…" : store.applications.isEmpty ? "Find installed apps to begin." : "No apps match your search.")
                                .foregroundStyle(Theme.secondary).padding(40)
                        }
                    }.padding(8)
                }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 16) {
                    if let app = store.applications.first(where: { $0.id == chosen?.id }) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 64, height: 64)
                        Text(app.name).font(.system(size: 23, weight: .semibold))
                        Text(app.bundle_id).font(.system(size: 12)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                        Text(app.path).font(.system(size: 11)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                        LabeledContent("App size", value: app.sizeText).font(.system(size: 12))
                        LabeledContent("Last active", value: app.lastActiveDate?.formatted(date: .abbreviated, time: .shortened) ?? app.lastActiveText)
                            .font(.system(size: 12)).help("macOS last-used metadata; may be delayed or unavailable.")
                        if let reason = app.reason {
                            Label(reason, systemImage: "lock.shield").font(.system(size: 12)).foregroundStyle(Theme.gold)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Review uninstall…") { review = app; store.reviewApplication(app) }
                            .buttonStyle(.borderedProminent).tint(Theme.green).disabled(store.busy || app.reason != nil)
                            .accessibilityLabel("Review uninstall for \(app.name)")
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }.disabled(store.busy)
                        Divider()
                        Text("Quit the app and its helpers first. The review measures the bundle and checks exact files associated with its bundle ID. App data is optional and starts unchecked.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    } else {
                        Image(systemName: "app.badge.checkmark").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.gold)
                        Text("Choose an app").font(.system(size: 22, weight: .semibold))
                        Text("Search or select an app on the left, then review its files before uninstalling.").foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    Label("Moves go to Trash. Empty it in Finder when you are ready.", systemImage: "trash").font(.system(size: 12)).foregroundStyle(Theme.green)
                }.padding(22).frame(width: 350, alignment: .leading).frame(maxHeight: .infinity)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            }
            Text(store.message).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
            if store.partial { Text("Partial inventory · Some locations could not be read. Refresh after checking access.").font(.system(size: 11)).foregroundStyle(Theme.gold) }
            Text("Apps in Applications folders · Homebrew apps, security tools, and shared files may need their own uninstallers.")
                .font(.system(size: 10)).foregroundStyle(Theme.secondary)
        }
        .task { if store.phase == .idle { store.scan() } }
        .sheet(item: $review, onDismiss: { chosen = nil; store.scan() }) { app in
            UninstallReview(store: store, app: app)
        }
    }
}

private struct UninstallReview: View {
    @ObservedObject var store: CleanStore
    let app: InstalledApplication
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    private var dataItems: [CleanItem] { store.selectedItems.filter { $0.category == "uninstall-data" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(store.phase == .finished ? "Uninstall results" : "Review \(app.name)").font(.system(size: 23, weight: .semibold))
            Text(store.message).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            if store.busy { ProgressView(value: store.progress).tint(Theme.green) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.items.sorted { $0.category == "uninstall-bundle" && $1.category != "uninstall-bundle" }) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("Select \(item.name)", isOn: Binding(get: { store.selected.contains(item.id) }, set: { selected in
                                if selected { store.selected.insert(item.id) } else { store.selected.remove(item.id) }
                                store.acknowledgedItems = []
                            })).labelsHidden().toggleStyle(.checkbox).disabled(store.phase != .ready)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.category == "uninstall-bundle" ? "App bundle" : "Optional app data").font(.system(size: 12, weight: .semibold))
                                Text(item.path).font(.system(size: 11)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                                if let outcome = store.resultMessages[item.id] { Text(outcome).font(.system(size: 11)).foregroundStyle(store.results[item.id] == "trashed" ? Theme.green : Theme.gold) }
                                else if store.phase == .finished { Text("Not processed").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                            }
                            Spacer()
                            Text(Format.bytes(item.bytes)).font(.system(size: 12)).monospacedDigit()
                        }.padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(store.refusals.keys.sorted(), id: \.self) { path in
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Kept", systemImage: "lock.shield").font(.system(size: 12, weight: .semibold))
                            Text(path).textSelection(.enabled)
                            Text(store.refusals[path] ?? "")
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        }.font(.system(size: 11)).foregroundStyle(Theme.gold).padding(14)
                    }
                }
            }.frame(minHeight: 210, maxHeight: 400)
            if !dataItems.isEmpty && store.phase == .ready {
                Toggle("Remove checked app data, including its settings and saved work.", isOn: Binding(
                    get: { dataItems.allSatisfy { store.acknowledgedItems.contains($0.id) } },
                    set: { store.acknowledgedItems = $0 ? Set(dataItems.map(\.id)) : [] }))
                    .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Theme.gold)
            }
            Text("Unchecked data stays. Shared containers, name-only matches, credentials in Keychain, and system helpers are kept. Trash moves can be undone in Finder; no disk space is freed until you empty Trash.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            HStack {
                Text("\(store.selected.count) checked · \(Format.bytes(store.selectedBytes)) estimated").font(.system(size: 12))
                Spacer()
                if store.busy {
                    Button(store.stopping ? "Stopping…" : "Stop") { store.cancel() }.disabled(store.stopping)
                } else {
                    Button(store.phase == .finished ? "Done" : "Cancel") { dismiss() }
                    if store.phase == .ready && !store.items.isEmpty {
                        Button("Uninstall…") { confirm = true }.buttonStyle(.borderedProminent).tint(Theme.gold).disabled(!store.canClean)
                    }
                }
            }
        }.padding(26).frame(width: 760).background(Theme.background).foregroundStyle(Theme.text).preferredColorScheme(.dark)
        .interactiveDismissDisabled(store.busy)
        .alert("Uninstall \(app.name)?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) {}
            Button("Move checked files to Trash", role: .destructive) { store.cleanSelected() }
        } message: {
            Text("The app bundle and \(dataItems.count) checked app-data items will move to Trash (\(Format.bytes(store.selectedBytes)) estimated). Close this app and save your work first. Unchecked data stays on this Mac.")
        }
    }
}
