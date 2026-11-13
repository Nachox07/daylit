// Telling the user a newer release exists: which GitHub release is newer than the running app, what changed
// since, and when to show the panel line. No self-install. windows/Update.cs is its twin, with the same tests.
import Foundation

public enum UpdateCheck {
    /// The releases, newest first. Nothing about the user is sent; the User-Agent carries only the app name and version.
    public static let releasesURL = "https://api.github.com/repos/Nachox07/daylit/releases?per_page=20"
    /// First check a little after start, then once a day while running.
    public static let startDelay: Double = 60
    public static let interval: Double = 24 * 3600
    public static let brewCommand = "brew upgrade --cask daylit"
    /// The panel's What's new list shows this many changes, then "and N more".
    public static let shownChanges = 8

    public static func userAgent(version: String?) -> String { "Daylit/" + (isDevBuild(version) ? "dev" : version!) }

    /// "1.5.1", "v1.5.1" or "1.5" as numbers; nil for anything else ("1.5-beta", "", "v").
    public static func parse(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.first == "v" || t.first == "V" { t.removeFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 9, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    /// Numeric, part by part; a missing part counts as 0 (1.5 = 1.5.0). False when either is not a version.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// A local build (no version, 0.0.0, or not a version): it never offers an update.
    public static func isDevBuild(_ version: String?) -> Bool {
        guard let v = version, let p = parse(v) else { return true }
        return p.allSatisfy { $0 == 0 }
    }

    /// The macOS app installed by Homebrew lives under …/Caskroom/daylit/<version>/: upgrading goes through brew.
    public static func isHomebrew(bundlePath: String) -> Bool { bundlePath.contains("/Caskroom/") }

    public struct Release: Equatable {
        public var tag: String, url: String, body: String
        public var draft: Bool, prerelease: Bool
        public init(tag: String, url: String, body: String = "", draft: Bool = false, prerelease: Bool = false) {
            self.tag = tag; self.url = url; self.body = body; self.draft = draft; self.prerelease = prerelease
        }
    }

    /// GitHub's /releases answer, or nil when it is not a list. Entries without a tag or a github.com page are skipped.
    public static func releases(json d: Data) -> [Release]? {
        guard let list = (try? JSONSerialization.jsonObject(with: d)) as? [Any] else { return nil }
        return list.compactMap { item in
            guard let o = item as? [String: Any], let tag = o["tag_name"] as? String,
                  let url = o["html_url"] as? String, url.hasPrefix("https://github.com/") else { return nil }
            return Release(tag: tag, url: url, body: o["body"] as? String ?? "",
                           draft: o["draft"] as? Bool ?? false, prerelease: o["prerelease"] as? Bool ?? false)
        }
    }

    public struct Available: Equatable {
        public var version: String       // without the "v"
        public var url: String           // the newest release's page
        public var changes: [String]     // every newer release's changes, newest first
        public init(version: String, url: String, changes: [String]) { self.version = version; self.url = url; self.changes = changes }
    }

    /// The newest release newer than `running` (drafts, prereleases and odd tags skipped), with the changes of every
    /// release newer than `running`, newest first. Nil for a dev build or when nothing is newer.
    public static func available(running: String?, releases: [Release]) -> Available? {
        guard !isDevBuild(running), let running else { return nil }
        let newer = releases.filter { !$0.draft && !$0.prerelease && parse($0.tag) != nil && isNewer($0.tag, than: running) }
            .sorted { isNewer($0.tag, than: $1.tag) }
        guard let top = newer.first else { return nil }
        var v = top.tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.first == "v" || v.first == "V" { v.removeFirst() }
        return Available(version: v, url: top.url, changes: newer.flatMap { changes(body: $0.body) })
    }

    /// Whether the panel shows "Daylit X.Y.Z is available". A check from the gear menu always shows what it found;
    /// otherwise only with checkUpdates on and not for a version the user put off with Not now (a newer one shows again).
    public static func showLine(_ a: Available?, dismissed: String?, checkUpdates: Bool, manual: Bool) -> Bool {
        guard let a else { return false }
        if manual { return true }
        guard checkUpdates else { return false }
        guard let d = dismissed else { return true }
        return isNewer(a.version, than: d)
    }

    /// The `* ` bullets under "## What's Changed" in a GitHub-generated release body, as plain text and without the
    /// trailing " by @user in <url>". It stops at a line that is not a bullet (Full Changelog, the next heading).
    /// A body without that section has no changes.
    public static func changes(body: String) -> [String] {
        var out: [String] = []
        var inside = false
        for raw in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !inside {
                if line.hasPrefix("##"), line.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "\u{2019}", with: "'") == "what's changed" { inside = true }
                continue
            }
            if line.isEmpty { continue }
            guard line.hasPrefix("* ") else { break }
            let text = plain(String(line.dropFirst(2)))
            if !text.isEmpty { out.append(text) }
        }
        return out
    }

    /// The first `cap` changes and how many more there are.
    public static func shown(_ changes: [String], cap: Int = shownChanges) -> (items: [String], more: Int) {
        (Array(changes.prefix(cap)), max(0, changes.count - cap))
    }

    static let byLine = try! NSRegularExpression(pattern: #"(?:^|\s+)by\s+@\S+(?:\s*(?:,|and)\s*@\S+)*\s+in\s+https?://\S+$"#)

    /// One change as plain text: the attribution dropped, at most 200 characters.
    static func plain(_ s: String) -> String {
        let r = NSRange(s.startIndex..., in: s)
        var t = byLine.stringByReplacingMatches(in: s, range: r, withTemplate: "").trimmingCharacters(in: .whitespaces)
        if t.count > 200 { t = String(t.prefix(199)) + "…" }
        return t
    }
}
