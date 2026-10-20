import SwiftUI

struct AnalyzeView: View {
    @EnvironmentObject private var analyze: AnalyzeStore
    @State private var largeFiles = false
    @State private var query = ""
    @State private var byName = false

    var body: some View {
        VStack(spacing: 16) {
            summary
            HStack(spacing: 10) {
                Button { analyze.scan(URL(fileURLWithPath: analyze.folder).deletingLastPathComponent().path) } label: {
                    Image(systemName: "arrow.up").frame(width: 22, height: 22)
                }.help("Scan parent folder").accessibilityLabel("Scan parent folder").disabled(analyze.busy || analyze.folder == "/")
                TextField("Absolute folder path", text: $analyze.folder)
                    .textFieldStyle(.roundedBorder).onSubmit { analyze.scan() }
                    .accessibilityLabel("Folder to analyze").disabled(analyze.busy)
                Button("Choose folder…") { analyze.chooseFolder() }.disabled(analyze.busy)
                if analyze.busy {
                    Button(analyze.stopping ? "Stopping…" : "Stop") { analyze.cancel() }.disabled(analyze.stopping)
                } else {
                    Button(analyze.result == nil ? "Scan folder" : "Scan again") { analyze.scan() }
                        .buttonStyle(.borderedProminent).tint(Theme.green).foregroundStyle(Theme.background)
                }
            }
            HStack(spacing: 12) {
                Button("Home") { analyze.scan(NSHomeDirectory()) }
                Button("User Library") { analyze.scan(NSHomeDirectory() + "/Library") }
                Button("Applications") { analyze.scan("/Applications") }
                Divider().frame(height: 14)
                breadcrumbs
                Spacer(minLength: 0)
            }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Theme.secondary).disabled(analyze.busy)
            HStack(spacing: 10) {
                if analyze.busy { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 20) }
                else { Image(systemName: analyze.result?.scan_status == .partial ? "exclamationmark.triangle" : "info.circle").foregroundStyle(Theme.gold) }
                Text(analyze.message).font(.system(size: 12)).lineLimit(2)
                Spacer()
                if analyze.busy {
                    Text("\(analyze.files.formatted()) files · \(analyze.directories.formatted()) folders checked")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).monospacedDigit()
                } else if let date = analyze.scannedAt {
                    Text(date, style: .time).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }.padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            if let result = analyze.result {
                HStack(alignment: .top, spacing: 16) {
                    mapPanel(result)
                    listPanel(result)
                }.frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(Theme.gold)
                    Text(analyze.busy ? "Finding where the space goes" : "Explore your disk, one folder at a time")
                        .font(.system(size: 20, weight: .medium))
                    Text(analyze.busy ? "The map appears when this scan finishes. You can stop at any time." : "Start with Home, Applications, or a folder you choose.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("Read-only · Mole skips some system and virtual-machine folders and does not follow symbolic links while measuring. Measured size is not reclaimable space.")
                .font(.system(size: 10)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.onChange(of: analyze.result?.path) { _, _ in query = ""; largeFiles = false }
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Analyze", systemImage: "chart.pie").font(.system(size: 25, weight: .semibold))
                Text("See the folders and files taking up space. Open a folder to explore further.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Label("Inspect sizes and reveal items in Finder", systemImage: "eye")
                    .font(.system(size: 11)).foregroundStyle(Theme.green)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(totalLabel).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(analyze.result.map { "\($0.entries.count.formatted()) direct items · \($0.scan_status.label.lowercased()) size" } ?? "Measured folder size")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }.padding(22).background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var totalLabel: String {
        guard let result = analyze.result, result.scan_status != .unavailable else { return "—" }
        return (result.scan_status == .partial ? "≥ " : "") + Format.bytes(UInt64(max(0, result.total_size)))
    }

    private var breadcrumbs: some View {
        let path = analyze.result?.path ?? analyze.folder
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        // Keep the last four components, with a direct route to the root.
        return HStack(spacing: 5) {
            Button("/") { analyze.scan("/") }.help("Scan root folder")
            if parts.count > 5 { Text("…") }
            ForEach(Array(parts.enumerated()).filter { $0.offset > 0 && $0.offset >= parts.count - 4 }, id: \.offset) { part in
                Image(systemName: "chevron.right").font(.system(size: 8))
                Button(part.element) {
                    analyze.scan(NSString.path(withComponents: Array(parts.prefix(part.offset + 1))))
                }.lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func mapPanel(_ result: AnalyzeResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Space map").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Click a folder to explore").font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            GeometryReader { geometry in
                let tiles = AnalyzeMap.tiles(result.entries)
                let rects = AnalyzeMap.layout(tiles, width: geometry.size.width, height: geometry.size.height)
                if rects.isEmpty {
                    Text("No measured space to map.\nEmpty and unavailable items remain in the list.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ZStack(alignment: .topLeading) {
                        ForEach(rects, id: \.tile.id) { rect in
                            let color = tileColor(rect.tile.id)
                            Button {
                                if let entry = rect.tile.entry { open(entry) }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    if rect.width > 65 && rect.height > 38 {
                                        Text(rect.tile.name).font(.system(size: rect.width > 130 ? 12 : 10, weight: .semibold)).lineLimit(2)
                                        if rect.height > 65 {
                                            Text(rect.tile.entry?.sizeLabel ?? Format.bytes(UInt64(rect.tile.bytes)))
                                                .font(.system(size: 10)).foregroundStyle(Theme.text.opacity(0.75)).lineLimit(1)
                                        }
                                    }
                                }.padding(rect.width > 65 ? 10 : 0)
                                    .frame(width: max(0, rect.width - 3), height: max(0, rect.height - 3), alignment: .topLeading)
                                    .background(color.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.4), lineWidth: 1))
                                    .clipped().contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(analyze.busy || rect.tile.entry == nil)
                                .help("\(rect.tile.name) · \(rect.tile.entry?.sizeLabel ?? Format.bytes(UInt64(rect.tile.bytes)))\(rect.tile.entry == nil ? " · See the list for these items" : "")")
                                .accessibilityLabel("\(rect.tile.name), \(rect.tile.entry?.sizeLabel ?? Format.bytes(UInt64(rect.tile.bytes)))")
                                .offset(x: rect.x, y: rect.y)
                        }
                    }
                }
            }
            Text("Area represents measured bytes. Partial sizes may grow; unavailable sizes have no area. Small items are grouped and listed individually.")
                .font(.system(size: 10)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private func listPanel(_ result: AnalyzeResult) -> some View {
        VStack(spacing: 12) {
            Picker("Show", selection: $largeFiles) {
                Text("Folders & files").tag(false)
                Text("Large files").tag(true)
            }.pickerStyle(.segmented)
            HStack {
                TextField("Filter by name or path", text: $query).textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $byName) { Text("Size ↓").tag(false); Text("Name").tag(true) }
                    .labelsHidden().frame(width: 100)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if largeFiles {
                        let files = (result.large_files ?? []).filter { matches($0.name, path: $0.path) }
                            .sorted { byName ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.size > $1.size }
                        ForEach(files) { file in
                            fileRow(name: file.name, path: file.path, icon: "doc", size: Format.bytes(UInt64(max(0, file.size)))) { analyze.reveal(file.path) }
                        }
                        if files.isEmpty { emptyList("No matching large files found.") }
                    } else {
                        let entries = result.entries.filter { matches($0.name, path: $0.path) }.sorted {
                            if byName { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                            if $0.scan_status == .unavailable && $1.scan_status != .unavailable { return false }
                            if $1.scan_status == .unavailable && $0.scan_status != .unavailable { return true }
                            return $0.size == $1.size ? $0.path < $1.path : $0.size > $1.size
                        }
                        ForEach(entries) { entry in
                            fileRow(name: entry.name, path: entry.path, icon: entry.browsable ? "folder" : entry.isLink ? "link" : "doc", size: entry.sizeLabel) { open(entry) }
                        }
                        if entries.isEmpty { emptyList(query.isEmpty ? "This folder has no listed items." : "No items match this filter.") }
                    }
                }
            }
            if largeFiles {
                Text("Up to 20 engine-discovered files of at least 1 MiB. Mole excludes some file types and may not enumerate files inside folded folders.")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private func fileRow(name: String, path: String, icon: String, size: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(Theme.blue).frame(width: 20)
                Button(action: action) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(path).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(path).accessibilityLabel("\(icon == "folder" ? "Explore" : "Reveal") \(name)")
                Text(size).font(.system(size: 11)).foregroundStyle(size.contains("Unavailable") || size.contains("At least") ? Theme.gold : Theme.secondary).monospacedDigit()
                Button { analyze.reveal(path) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.plain).help("Reveal in Finder").accessibilityLabel("Reveal \(name) in Finder")
            }.padding(.vertical, 11).disabled(analyze.busy)
            Divider().overlay(Theme.border)
        }
    }

    private func open(_ entry: AnalyzeEntry) {
        query = ""
        if entry.browsable { largeFiles = false; analyze.scan(entry.path) }
        else { analyze.reveal(entry.path) }
    }
    private func matches(_ name: String, path: String) -> Bool { query.isEmpty || name.localizedCaseInsensitiveContains(query) || path.localizedCaseInsensitiveContains(query) }
    private func emptyList(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(32) }
    private func tileColor(_ path: String) -> Color {
        let colors = [Theme.green, Theme.blue, Theme.gold, Color(red: 0.70, green: 0.55, blue: 0.82), Color(red: 0.80, green: 0.50, blue: 0.37)]
        return colors[path.utf8.reduce(0) { ($0 + Int($1)) % colors.count }]
    }
}
