import Foundation
import Darwin

// Fixed native transport for Mole's existing `trash <exact path>` call.
// Policy, plan identity, and live-owner validation remain in Mole's funnel.
guard geteuid() != 0, CommandLine.arguments.count == 2,
      CommandLine.arguments[1].hasPrefix("/") else { exit(64) }
do {
    try FileManager.default.trashItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), resultingItemURL: nil)
} catch {
    fputs("macOS could not move this item to Trash: \(error.localizedDescription)\n", stderr)
    exit(1)
}
