import Foundation

@main
enum ModelContract {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let frame = try JSONDecoder().decode(Snapshot.self, from: data)
        precondition(frame.memory.total > 0)
        precondition(frame.enriched)
        precondition((frame.processes?.count ?? 0) > 5)
        precondition(Format.temperature(0) == "—")
        precondition(Format.temperature(nil) == "—")
        precondition(Format.temperature(42) == "42°")
        precondition(Format.rate(-1) == "—")
        precondition(Format.number(.nan) == "—")
        let helper = RunningProcess(pid: 1, ppid: 0, name: "Browser Helper", command: "/Applications/Browser.app/Contents/MacOS/Browser Helper", cpu: 250, memory: 1, memory_bytes: 1024)
        precondition(helper.displayName == "Browser")
        precondition(helper.appPath == "/Applications/Browser.app")
        precondition(helper.cpu == 250)
        print("Swift live-schema decoding and unavailable-value checks passed")
    }
}
