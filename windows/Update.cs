// Telling the user a newer release exists: which GitHub release is newer than the running app, what changed
// since, and when to show the panel line. No self-install. Twin of mac/Sources/DaylitCore/Update.swift, with the
// same tests. No WPF or Win32 here: the test project compiles this file. The request itself is in Updates.cs.
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Daylit;

static class UpdateCheck {
    /// The releases, newest first. Nothing about the user is sent; the User-Agent carries only the app name and version.
    public const string ReleasesUrl = "https://api.github.com/repos/Nachox07/daylit/releases?per_page=20";
    /// First check a little after start, then once a day while running.
    public static readonly TimeSpan StartDelay = TimeSpan.FromSeconds(60), Interval = TimeSpan.FromHours(24);
    /// The panel's What's new list shows this many changes, then "and N more".
    public const int ShownChanges = 8;

    public static string UserAgent(string? version) => "Daylit/" + (IsDevBuild(version) ? "dev" : version);

    /// "1.5.1", "v1.5.1" or "1.5" as numbers; null for anything else ("1.5-beta", "", "v").
    public static int[]? Parse(string? s) {
        var t = (s ?? "").Trim();
        if (t.StartsWith('v') || t.StartsWith('V')) t = t[1..];
        var parts = t.Split('.');
        if (parts.Length is < 1 or > 4) return null;
        var o = new int[parts.Length];
        for (int i = 0; i < parts.Length; i++) {
            var p = parts[i];
            if (p.Length is 0 or > 9 || !p.All(char.IsAsciiDigit)) return null;
            o[i] = int.Parse(p, System.Globalization.CultureInfo.InvariantCulture);
        }
        return o;
    }

    /// Numeric, part by part; a missing part counts as 0 (1.5 = 1.5.0). False when either is not a version.
    public static bool IsNewer(string a, string b) {
        if (Parse(a) is not { } x || Parse(b) is not { } y) return false;
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++) {
            int p = i < x.Length ? x[i] : 0, q = i < y.Length ? y[i] : 0;
            if (p != q) return p > q;
        }
        return false;
    }

    /// A local build (no version, 0.0.0, or not a version): it never offers an update.
    public static bool IsDevBuild(string? version) => Parse(version) is not { } p || p.All(n => n == 0);

    public sealed record Release(string Tag, string Url, string Body = "", bool Draft = false, bool Prerelease = false);

    /// GitHub's /releases answer, or null when it is not a list. Entries without a tag or a github.com page are skipped.
    public static List<Release>? Releases(string json) {
        try {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return null;
            var list = new List<Release>();
            foreach (var o in doc.RootElement.EnumerateArray()) {
                if (o.ValueKind != JsonValueKind.Object) continue;
                string? Str(string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
                bool Flag(string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
                if (Str("tag_name") is not { } tag || Str("html_url") is not { } url || !url.StartsWith("https://github.com/", StringComparison.Ordinal)) continue;
                list.Add(new Release(tag, url, Str("body") ?? "", Flag("draft"), Flag("prerelease")));
            }
            return list;
        } catch (JsonException) { return null; }
    }

    /// `Version` without the "v"; `Url` the newest release's page; `Changes` every newer release's changes, newest first.
    public sealed record Available(string Version, string Url, IReadOnlyList<string> Changes);

    /// The newest release newer than `running` (drafts, prereleases and odd tags skipped), with the changes of every
    /// release newer than `running`, newest first. Null for a dev build or when nothing is newer.
    public static Available? Find(string? running, IEnumerable<Release> releases) {
        if (IsDevBuild(running)) return null;
        var newer = releases.Where(r => !r.Draft && !r.Prerelease && Parse(r.Tag) != null && IsNewer(r.Tag, running!)).ToList();
        newer.Sort((a, b) => IsNewer(a.Tag, b.Tag) ? -1 : IsNewer(b.Tag, a.Tag) ? 1 : 0);
        if (newer.Count == 0) return null;
        var v = newer[0].Tag.Trim();
        if (v.StartsWith('v') || v.StartsWith('V')) v = v[1..];
        return new Available(v, newer[0].Url, newer.SelectMany(r => Changes(r.Body)).ToList());
    }

    /// Whether the panel shows "Daylit X.Y.Z is available". A check from the gear menu always shows what it found;
    /// otherwise only with checkUpdates on and not for a version the user put off with Not now (a newer one shows again).
    public static bool ShowLine(Available? a, string? dismissed, bool checkUpdates, bool manual) {
        if (a == null) return false;
        if (manual) return true;
        if (!checkUpdates) return false;
        return dismissed == null || IsNewer(a.Version, dismissed);
    }

    /// The `* ` bullets under "## What's Changed" in a GitHub-generated release body, as plain text and without the
    /// trailing " by @user in <url>". It stops at a line that is not a bullet (Full Changelog, the next heading).
    /// A body without that section has no changes.
    public static List<string> Changes(string? body) {
        var o = new List<string>();
        bool inside = false;
        foreach (var raw in (body ?? "").Replace("\r\n", "\n").Split('\n')) {
            var line = raw.Trim(' ', '\t');
            if (!inside) {
                if (line.StartsWith("##", StringComparison.Ordinal)
                    && line[2..].Trim(' ', '\t').ToLowerInvariant().Replace('’', '\'') == "what's changed") inside = true;
                continue;
            }
            if (line == "") continue;
            if (!line.StartsWith("* ", StringComparison.Ordinal)) break;
            var text = Plain(line[2..]);
            if (text != "") o.Add(text);
        }
        return o;
    }

    /// The first `cap` changes and how many more there are.
    public static (List<string> Items, int More) Shown(IReadOnlyList<string> changes, int cap = ShownChanges) =>
        (changes.Take(cap).ToList(), Math.Max(0, changes.Count - cap));

    static readonly Regex ByLine = new(@"(?:^|\s+)by\s+@\S+(?:\s*(?:,|and)\s*@\S+)*\s+in\s+https?://\S+$", RegexOptions.CultureInvariant);

    /// One change as plain text: the attribution dropped, at most 200 characters.
    static string Plain(string s) {
        var t = ByLine.Replace(s, "").Trim(' ', '\t');
        var e = System.Globalization.StringInfo.ParseCombiningCharacters(t);
        if (e.Length > 200) t = t[..e[199]] + "…";
        return t;
    }
}
