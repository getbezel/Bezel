import AppKit

@MainActor enum DWFinderPlacement {
    /// Optional positioning only. Failure cannot turn a successful conversion
    /// into a failed one or remove the converted file.
    static func place(_ item: URL, nextTo original: URL) {
        func literal(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = """
        with timeout of 2 seconds
            tell application "Finder"
                set srcItem to (POSIX file "\(literal(original.path))") as alias
                set dstItem to (POSIX file "\(literal(item.path))") as alias
                set c to container of srcItem
                try
                    update c
                    set p to position of srcItem
                    set position of dstItem to {(item 1 of p) + 110, item 2 of p}
                end try
            end tell
        end timeout
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }
}
