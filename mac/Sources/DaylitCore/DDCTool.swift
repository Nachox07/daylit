// Which program Daylit may run as the DDC tool. config.json can sit in iCloud Drive and be written by any Mac
// on the account, so its `ddcTool` must never choose an arbitrary program: only Homebrew's m1ddc is run.
import Foundation

public enum DDCToolRule {
    /// The Homebrew locations of m1ddc.
    public static let known = ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"]
    /// Where those links point: the Homebrew Cellar.
    static let cellars = ["/opt/homebrew/Cellar/", "/usr/local/Cellar/"]

    public static let note = "ddcTool ignored: only m1ddc from Homebrew is run"

    /// The program to run for the configured `ddcTool`, or nil to use the default; plus a note when the
    /// configured value was ignored. Accepted: a Homebrew location above, or the place one of those links
    /// resolves to, under the Homebrew Cellar. Anything else is ignored. (A bare name or a PATH folder is not
    /// accepted: the app started at login has launchd's short PATH, so the terminal and the app would disagree.)
    public static func resolve(configured: String?,
                               resolvingLinks: (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) -> (path: String?, note: String?) {
        guard let raw = configured?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return (nil, nil) }
        if known.contains(raw) { return (raw, nil) }
        if raw.hasPrefix("/"), URL(fileURLWithPath: raw).standardizedFileURL.path == raw,
           cellars.contains(where: raw.hasPrefix), known.contains(where: { resolvingLinks($0) == raw }) { return (raw, nil) }
        return (nil, note)
    }
}
