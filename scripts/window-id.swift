// Prints the CGWindowID of the first on-screen window owned by <pid> whose
// title contains <title>. Used by snapshots.sh to screenshot real windows.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let pid = Int(args[1]) else { exit(2) }
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int) == pid {
    if let name = window[kCGWindowName as String] as? String, name.contains(args[2]),
       let id = window[kCGWindowNumber as String] as? Int {
        print(id)
        exit(0)
    }
}
exit(1)
