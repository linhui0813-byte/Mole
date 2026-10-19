import AppKit
import SwiftUI

private enum Theme {
    static let background = Color(red: 0.105, green: 0.100, blue: 0.078)
    static let card = Color(red: 0.175, green: 0.163, blue: 0.124)
    static let border = Color.white.opacity(0.085)
    static let text = Color(red: 0.94, green: 0.93, blue: 0.89)
    static let secondary = Color(red: 0.65, green: 0.64, blue: 0.58)
    static let green = Color(red: 0.32, green: 0.76, blue: 0.61)
    static let gold = Color(red: 0.88, green: 0.72, blue: 0.39)
    static let blue = Color(red: 0.39, green: 0.65, blue: 0.90)
    static let red = Color(red: 0.96, green: 0.43, blue: 0.41)
}

private struct Chip: View {
    let text: String
    var color: Color = Theme.secondary
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .lineLimit(1)
    }
}

private struct MetricCard<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = Theme.green
    var tag: String = ""
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: icon).foregroundStyle(tint).font(.system(size: 14))
                Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.5)
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 6)
                if !tag.isEmpty { Chip(text: tag) }
            }.padding(.bottom, 20)
            content
        }
        .padding(20).frame(maxWidth: .infinity, minHeight: 208, maxHeight: 208, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.border, lineWidth: 1))
    }
}

private struct BigValue: View {
    let value: String
    var unit: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.system(size: 37, weight: .semibold, design: .rounded)).monospacedDigit()
            if !unit.isEmpty { Text(unit).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.secondary) }
        }.foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.7)
    }
}

private struct Footnote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
}

private struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.green
    var domain: Double? = nil
    var body: some View {
        GeometryReader { geo in
            let samples = values.filter { $0.isFinite }
            let ceiling = max(domain ?? samples.max() ?? 1, 0.001)
            if samples.count > 1 {
                Path { path in
                    for (index, sample) in samples.enumerated() {
                        let point = CGPoint(x: geo.size.width * Double(index) / Double(max(samples.count - 1, 1)),
                                            y: geo.size.height * (1 - min(max(sample / ceiling, 0), 1)))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }.stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityLabel("Recent readings").frame(height: 39)
    }
}

private struct HistoryBars: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<20, id: \.self) { index in
                    let samples = Array(values.suffix(20))
                    let offset = 20 - samples.count
                    let value = index >= offset ? samples[index - offset] : nil
                    RoundedRectangle(cornerRadius: 2)
                        .fill(value == nil ? Color.white.opacity(0.035) : Theme.green.opacity(0.8))
                        .frame(height: value.map { max(3, geo.size.height * min(max($0, 0), 100) / 100) } ?? 3)
                }
            }.frame(height: geo.size.height, alignment: .bottom)
        }.frame(height: 40).accessibilityLabel("CPU usage history")
    }
}

private struct Meter: View {
    let fraction: Double
    var color: Color = Theme.green
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Color.white.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule().fill(color.opacity(0.85)).frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
        }.frame(height: 10)
    }
}

struct DashboardView: View {
    @EnvironmentObject var store: DashboardStore
    @State private var processOnly = false
    @State private var query = ""
    @State private var sort: ProcessSort = .cpu
    @State private var selectedPID: Int?
    @State private var details: RunningProcess?
    @State private var showAbout = false
    private var s: Snapshot? { store.snapshot }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 18) {
                header
                if let error = store.error {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.gold)
                        Text(error).font(.system(size: 12))
                        Spacer()
                        Button("Reconnect") { store.reconnect() }.buttonStyle(.bordered)
                    }.padding(12).background(Theme.gold.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                if !processOnly {
                    let columns = geometry.size.width > 1050 ? 4 : 2
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 14) {
                        healthCard
                        cpuCard
                        gpuCard
                        memoryCard
                        temperatureCard
                        diskCard
                        networkCard
                        fanCard
                    }
                }
                processTable
                footer
            }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 1100, minHeight: 780)
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showAbout) { aboutSheet }
        .sheet(item: $details) { process in processDetails(process) }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Image(nsImage: DashboardBrand.logo).resizable().scaledToFit()
                    .frame(width: 36, height: 36).accessibilityLabel("Mole logo")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mole Dashboard").font(.system(size: 16, weight: .semibold))
                    Text("Your Mac, at a glance").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                navButton("Status", selected: !processOnly) { processOnly = false }
                navButton("Processes", selected: processOnly) { processOnly = true }
            }.padding(4).background(Color.white.opacity(0.05), in: Capsule())
            Spacer()
            HStack(spacing: 10) {
                Circle().fill(store.live ? Theme.green : Theme.gold).frame(width: 6, height: 6)
                Text(store.status).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                Button { store.togglePause() } label: {
                    Image(systemName: store.paused ? "play.fill" : "pause.fill").frame(width: 22, height: 24)
                }.buttonStyle(.plain).help(store.paused ? "Resume readings" : "Pause readings")
                    .accessibilityLabel(store.paused ? "Resume readings" : "Pause readings")
                Button { showAbout = true } label: { Image(systemName: "info.circle").frame(width: 20, height: 24) }
                    .buttonStyle(.plain).help("About Mole Dashboard").accessibilityLabel("About Mole Dashboard")
            }
        }.frame(height: 56).padding(.bottom, 6)
    }

    private func navButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Theme.background : Theme.secondary)
                .padding(.horizontal, 22).padding(.vertical, 9)
                .background(selected ? Theme.text : .clear, in: Capsule())
        }.buttonStyle(.plain)
    }

    private var healthCard: some View {
        MetricCard(title: "Health", icon: "sun.max", tag: s?.hardware.cpu_model.replacingOccurrences(of: "Apple ", with: "") ?? "") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    BigValue(value: s.map { String($0.health_score) } ?? "—")
                    Text(healthLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.green)
                    Text(s?.health_score_msg ?? "Collecting your first readings")
                        .font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                ZStack {
                    Circle().stroke(Theme.gold.opacity(0.10), lineWidth: 8)
                    Circle().trim(from: 0, to: Double(s?.health_score ?? 0) / 100)
                        .stroke(Theme.gold, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "sun.max.fill").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(Theme.gold)
                }.frame(width: 82, height: 82).accessibilityHidden(true)
            }
            Spacer()
            Footnote(text: s.map { "Up \($0.uptime) · \($0.hardware.total_ram) RAM" } ?? "Checking hardware")
        }
    }

    private var healthLabel: String {
        guard let value = s?.health_score else { return "Reading" }
        return value >= 85 ? "Excellent" : value >= 65 ? "Good" : value >= 45 ? "Fair" : "Needs attention"
    }

    private var cpuCard: some View {
        MetricCard(title: "CPU", icon: "cpu", tag: s.map { "\($0.cpu.logical_cpu) cores" } ?? "") {
            BigValue(value: s.map { Format.number($0.cpu.usage) } ?? "—", unit: "%")
            Spacer(minLength: 10)
            HistoryBars(values: store.cpuHistory)
            Spacer(minLength: 12)
            Footnote(text: s.map { "Load average \(Format.number($0.cpu.load1, digits: 1)) · system total" } ?? "Measuring CPU activity")
        }
    }

    private var gpuCard: some View {
        MetricCard(title: "GPU", icon: "square.stack.3d.up", tint: Theme.gold,
                   tag: (s?.primaryGPU?.core_count ?? 0) > 0 ? "\(s!.primaryGPU!.core_count) cores" : "") {
            let gpu = s?.primaryGPU
            BigValue(value: gpu.map { $0.usage >= 0 ? Format.number($0.usage) : "—" } ?? "—", unit: gpu?.usage ?? -1 >= 0 ? "%" : "")
            Spacer()
            if let gpu, gpu.usage >= 0 {
                Sparkline(values: store.gpuHistory, color: Theme.gold, domain: 100)
            } else {
                Footnote(text: "Usage is not exposed to this collector")
            }
            Spacer()
            Footnote(text: gpu?.name.isEmpty == false ? gpu!.name : "Reading graphics hardware")
        }
    }

    private var memoryCard: some View {
        MetricCard(title: "Memory", icon: "memorychip", tint: Theme.gold, tag: s?.pressureLabel ?? "Reading") {
            BigValue(value: s.map { Format.number($0.memory.used_percent) } ?? "—", unit: "%")
            Spacer()
            Sparkline(values: store.memoryHistory, color: Theme.gold, domain: 100)
            Spacer()
            Footnote(text: s.map { "\(Format.bytes($0.memory.used)) used · \(Format.bytes($0.memory.swap_used)) swap" } ?? "Measuring memory")
        }
    }

    private var temperatureCard: some View {
        MetricCard(title: "Temperature", icon: "thermometer.medium", tag: thermalState) {
            HStack(spacing: 18) {
                BigValue(value: Format.temperature(s?.thermal.cpu_temp), unit: "CPU")
                BigValue(value: Format.temperature(s?.thermal.gpu_temp), unit: "GPU")
            }
            Spacer()
            if let t = s?.thermal.cpu_temp, t > 0 { Meter(fraction: t / 110) }
            else { Footnote(text: "CPU and GPU sensors are unavailable") }
            Spacer()
            Footnote(text: (s?.thermal.battery_temp ?? 0) > 0 ? "Battery \(Format.temperature(s?.thermal.battery_temp))C · separate sensor" : "Thermal state is reported by macOS")
        }
    }

    private var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var diskCard: some View {
        MetricCard(title: "Available space", icon: "externaldrive", tint: Theme.blue,
                   tag: s?.startupDisk.map { Format.bytes($0.total) } ?? "") {
            let disk = s?.startupDisk
            BigValue(value: disk.map { Format.bytes($0.total > $0.used ? $0.total - $0.used : 0) } ?? "—")
            Spacer()
            Meter(fraction: (disk?.used_percent ?? 0) / 100, color: Theme.blue)
            Spacer()
            Footnote(text: disk.map { "\(Format.bytes($0.used)) used · \(Format.number($0.used_percent))% · startup disk" } ?? "Reading startup disk")
        }
    }

    private var networkCard: some View {
        MetricCard(title: "Network", icon: "globe", tint: Theme.blue, tag: s?.network?.first?.name ?? "") {
            BigValue(value: s.map { Format.rate($0.download) } ?? "—")
            Spacer()
            ZStack {
                let ceiling = max((store.downloadHistory + store.uploadHistory).max() ?? 0, 0.01)
                Sparkline(values: store.downloadHistory, color: Theme.blue, domain: ceiling)
                Sparkline(values: store.uploadHistory, color: Theme.green, domain: ceiling)
            }
            Spacer()
            Footnote(text: s.map { "↓ Download · ↑ \(Format.rate($0.upload)) upload" } ?? "Measuring network traffic")
        }
    }

    private var fanCard: some View {
        MetricCard(title: "Fans", icon: "fan", tint: Theme.gold, tag: "Read only") {
            BigValue(value: (s?.thermal.fan_speed ?? 0) > 0 ? String(s!.thermal.fan_speed) : "—", unit: "RPM")
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield").foregroundStyle(Theme.green)
                Footnote(text: "Managed by macOS")
            }
            Spacer()
            Footnote(text: (s?.thermal.fan_speed ?? 0) > 0 ? "Fan speed from the system collector" : "Fan speed is not exposed on this Mac")
        }
    }

    enum ProcessSort: String, CaseIterable {
        case cpu = "CPU", memory = "Memory", name = "Name"
    }
    private var rows: [RunningProcess] {
        var values = (s?.processes ?? []).filter {
            query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.name.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)
        }
        values.sort { a, b in
            switch sort {
            case .cpu: return a.cpu == b.cpu ? a.pid < b.pid : a.cpu > b.cpu
            case .memory: return a.memory_bytes == b.memory_bytes ? a.pid < b.pid : (a.memory_bytes ?? 0) > (b.memory_bytes ?? 0)
            case .name: return a.displayName == b.displayName ? a.pid < b.pid : a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        }
        return values
    }

    private var processTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Processes").font(.system(size: 13, weight: .semibold))
                Text("\(s?.processes?.count ?? 0)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                if s?.process_stale == true { Chip(text: "Previous sample", color: Theme.gold) }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                    TextField("Find a process or PID", text: $query).textFieldStyle(.plain).font(.system(size: 11))
                        .accessibilityLabel("Find a process or PID")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.padding(.horizontal, 10).padding(.vertical, 7).frame(width: 205)
                    .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                Picker("Sort", selection: $sort) {
                    ForEach(ProcessSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 100).accessibilityLabel("Sort processes")
            }.padding(.horizontal, 18).padding(.vertical, 13)
            HStack {
                columnHeading("NAME", sortBy: .name).frame(maxWidth: .infinity, alignment: .leading)
                columnHeading("MEMORY", sortBy: .memory).frame(width: 125, alignment: .trailing)
                columnHeading("% CPU", sortBy: .cpu).frame(width: 170, alignment: .trailing)
                Text("PID").frame(width: 85, alignment: .trailing)
                Color.clear.frame(width: 24, height: 1)
            }.font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 20).padding(.bottom, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
            if s?.processes == nil {
                Spacer()
                ProgressView().controlSize(.small)
                Footnote(text: "Reading the process table").padding(12)
                Spacer()
            } else if rows.isEmpty {
                Spacer()
                Text("No processes match “\(query)”").foregroundStyle(Theme.secondary).font(.system(size: 13))
                Button("Clear search") { query = "" }.buttonStyle(.borderless).padding(10)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in processRow(row) }
                    }.padding(.vertical, 5)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
    }

    private func columnHeading(_ title: String, sortBy: ProcessSort) -> some View {
        Button { sort = sortBy } label: {
            HStack(spacing: 5) {
                Text(title)
                if sort == sortBy { Image(systemName: sortBy == .name ? "chevron.up" : "chevron.down").font(.system(size: 8)) }
            }
        }.buttonStyle(.plain).help("Sort by \(sortBy.rawValue.lowercased())")
    }

    private func processRow(_ row: RunningProcess) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: store.icon(for: row)).resizable().aspectRatio(contentMode: .fit).frame(width: 23, height: 23)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if row.displayName != row.name {
                    Text(row.name).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if row.cpu >= 100 {
                Image(systemName: "flame").font(.system(size: 12)).foregroundStyle(Theme.red).help("Using more than one CPU core")
            }
            Text(row.memory_bytes.map(Format.bytes) ?? "—").font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Theme.secondary).frame(width: 125, alignment: .trailing)
            HStack(spacing: 14) {
                Meter(fraction: row.cpu / Double(max(s?.cpu.logical_cpu ?? 1, 1)) / 100,
                      color: row.cpu >= 100 ? Theme.red : Theme.green).frame(width: 62, height: 5)
                Text(Format.number(row.cpu, digits: 1)).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(row.cpu >= 100 ? Theme.red : Theme.secondary).frame(width: 57, alignment: .trailing)
            }.frame(width: 170, alignment: .trailing)
            Text(String(row.pid)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                .frame(width: 85, alignment: .trailing)
            Button { details = row } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .buttonStyle(.plain).help("Inspect \(row.displayName)").accessibilityLabel("Inspect \(row.displayName), PID \(row.pid)")
        }.padding(.horizontal, 20).frame(height: 44)
            .background(selectedPID == row.pid ? Theme.gold.opacity(0.10) : Color.clear)
            .contentShape(Rectangle()).onTapGesture { selectedPID = row.pid }
            .contextMenu {
                Button("Inspect process") { details = row }
                Button("Copy PID") { copy(String(row.pid)) }
            }
    }

    private var footer: some View {
        HStack {
            Text(s?.hardware.os_version.isEmpty == false ? "\(s!.hardware.model) · \(s!.hardware.os_version)" : "Mole status collector")
            Spacer()
            if store.paused { Text("Paused · readings are frozen") }
            else if store.stale { Text("Readings are delayed") }
            else if let date = store.receivedAt { Text("Updated \(date.formatted(date: .omitted, time: .standard))") }
            Text("·").padding(.horizontal, 4)
            Text("Read only").foregroundStyle(Theme.green)
        }.font(.system(size: 10)).foregroundStyle(Theme.secondary)
    }

    private var aboutSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: DashboardBrand.logo).resizable().scaledToFit().frame(width: 44, height: 44)
                Text("Mole Dashboard").font(.system(size: 24, weight: .semibold))
            }
            Text("A local, read-only Mac dashboard built from Mole’s open-source status collectors.")
            Text("Readings continue while the app runs, including when its window is closed. Use the Mole menu bar icon to reopen the dashboard, pause readings, or quit. Hardware details refresh every 30 seconds. A dash means the collector cannot provide that reading.")
            Text("Process CPU can exceed 100% when it uses multiple cores. Each table row is one process; memory is resident memory, not an app-wide total.")
            Text("This is an independent local build, not the commercial Mole Mac app. No cleanup, fan control, login item or background service is installed.")
            Link("Mole source and GPL-3.0 license", destination: URL(string: "https://github.com/tw93/Mole")!)
            HStack { Spacer(); Button("Done") { showAbout = false }.keyboardShortcut(.defaultAction) }
        }.font(.system(size: 13)).padding(28).frame(width: 500)
    }

    private func processDetails(_ row: RunningProcess) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: store.icon(for: row)).resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.displayName).font(.system(size: 20, weight: .semibold))
                    Text("PID \(row.pid) · Parent \(row.ppid)").foregroundStyle(.secondary)
                }
            }
            Text("\(Format.number(row.cpu, digits: 1))% CPU · \(row.memory_bytes.map(Format.bytes) ?? "Unknown memory")")
            Text(row.command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("This is one process, sampled when you opened this panel. 100% CPU represents one fully used core.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("Copy PID") { copy(String(row.pid)) }
                Spacer()
                Button("Done") { details = nil }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 530)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
