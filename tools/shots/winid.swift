// Prints the CGWindowID of the first on-screen window owned by a process name.
import CoreGraphics
let name = CommandLine.arguments.dropFirst().first ?? "Sky"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
if let w = list.first(where: { ($0[kCGWindowOwnerName as String] as? String) == name && ($0[kCGWindowLayer as String] as? Int) == 0 }) {
    print(w[kCGWindowNumber as String]!)
}
