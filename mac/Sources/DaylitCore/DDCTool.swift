// Which program Daylit may run as the DDC tool. config.json can sit in iCloud Drive and be written by any Mac
// on the account, so its `ddcTool` must never choose an arbitrary program: only m1ddc is run.
import Foundation

public enum DDCToolRule {
    /// The Homebrew locations of m1ddc.
    public static let known = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]

    public static let note = "ddcTool in config.json is ignored: only m1ddc is run (a Homebrew path, or a file named m1ddc in a PATH folder)"

    /// The program to run for the configured `ddcTool`, or nil to use the default; plus a note when the
    /// configured value was ignored. Accepted: a Homebrew path above, or a file named m1ddc that is in one of
    /// the PATH folders (`pathDirs`), given by its full path or as the bare name. Anything else is ignored.
    public static func resolve(configured: String?, pathDirs: [String],
                               exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> (path: String?, note: String?) {
        guard let raw = configured?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return (nil, nil) }
        let onPath = pathDirs.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).standardizedFileURL.path + "/m1ddc" }
        if known.contains(raw) { return (raw, nil) }
        if raw == "m1ddc", let hit = onPath.first(where: exists) { return (hit, nil) }
        if raw.hasPrefix("/"), URL(fileURLWithPath: raw).standardizedFileURL.path == raw, onPath.contains(raw) { return (raw, nil) }
        return (nil, note)
    }

    /// The folders of the PATH variable.
    public static func pathDirs(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        (env["PATH"] ?? "").split(separator: ":").map(String.init)
    }
}
