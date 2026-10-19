import Foundation

struct Snapshot: Decodable {
    let collected_at: String
    let host: String
    let platform: String
    let uptime: String
    let uptime_seconds: UInt64
    let hardware: Hardware
    let health_score: Int
    let health_score_msg: String
    let cpu: CPU
    let gpu: [GPU]?
    let memory: Memory
    let disks: [Disk]?
    let disk_io: DiskIO
    let network: [Network]?
    let thermal: Thermal
    let batteries: [Battery]?
    let processes: [RunningProcess]?
    let process_stale: Bool?
    let process_collected_at: String?
    let collection_error: String?
    let enriched: Bool

    struct Hardware: Decodable {
        let model: String
        let cpu_model: String
        let total_ram: String
        let os_version: String
    }
    struct CPU: Decodable {
        let usage: Double
        let load1: Double
        let core_count: Int
        let logical_cpu: Int
        let per_core: [Double]?
    }
    struct GPU: Decodable {
        let name: String
        let usage: Double
        let core_count: Int
        let note: String
    }
    struct Memory: Decodable {
        let used: UInt64
        let total: UInt64
        let used_percent: Double
        let swap_used: UInt64
        let pressure: String
    }
    struct Disk: Decodable {
        let mount: String
        let used: UInt64
        let total: UInt64
        let used_percent: Double
    }
    struct DiskIO: Decodable { let read_rate: Double; let write_rate: Double }
    struct Network: Decodable {
        let name: String
        let rx_rate_mbs: Double
        let tx_rate_mbs: Double
    }
    struct Thermal: Decodable {
        let cpu_temp: Double
        let gpu_temp: Double
        let fan_speed: Int
        let battery_temp: Double
    }
    struct Battery: Decodable { let percent: Double; let status: String; let health: String }

    var startupDisk: Disk? { disks?.first(where: { $0.mount == "/" }) ?? disks?.first }
    var primaryGPU: GPU? { gpu?.first }
    var download: Double { (network ?? []).reduce(0) { $0 + $1.rx_rate_mbs } }
    var upload: Double { (network ?? []).reduce(0) { $0 + $1.tx_rate_mbs } }
    var pressureLabel: String {
        switch memory.pressure {
        case "normal": return "Normal pressure"
        case "warn": return "Elevated pressure"
        case "critical": return "High pressure"
        default: return enriched ? "Pressure unavailable" : "Reading pressure"
        }
    }
}

struct RunningProcess: Decodable, Identifiable {
    let pid: Int
    let ppid: Int
    let name: String
    let command: String
    let cpu: Double
    let memory: Double
    let memory_bytes: UInt64?
    var id: Int { pid }
    var displayName: String {
        if let end = command.range(of: ".app/") {
            let path = String(command[..<end.lowerBound]) + ".app"
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        return name.isEmpty ? "Process \(pid)" : name
    }
    var appPath: String? {
        guard let end = command.range(of: ".app/") else { return nil }
        return String(command[..<end.lowerBound]) + ".app"
    }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal)
    }
    static func number(_ value: Double, digits: Int = 0) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.*f", digits, value)
    }
    static func rate(_ megabytes: Double) -> String {
        guard megabytes.isFinite, megabytes >= 0 else { return "—" }
        if megabytes >= 1 { return "\(number(megabytes, digits: 1)) MB/s" }
        return "\(number(megabytes * 1024)) KB/s"
    }
    static func temperature(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return "\(number(value))°"
    }
}
