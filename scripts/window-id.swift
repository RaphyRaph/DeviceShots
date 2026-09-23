// Prints the CGWindowID of an on-screen window owned by <pid>: the first one
// whose title contains <title>, or with --menu the largest open menu (menus
// have no title and sit above normal windows). Used to screenshot real windows.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let pid = Int(args[1]) else { exit(2) }
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    .filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }

func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}

let match: [String: Any]?
if args[2] == "--menu" {
    match = windows
        .filter { ($0[kCGWindowLayer as String] as? Int ?? 0) >= 101 }  // NSPopUpMenuWindowLevel
        .max { area($0) < area($1) }
} else {
    match = windows.first { ($0[kCGWindowName as String] as? String)?.contains(args[2]) == true }
}
guard let id = match?[kCGWindowNumber as String] as? Int else { exit(1) }
print(id)
