// Telling the user a newer Daylit is out (Update.cs). Once a little after start, then once a day, one GET to
// GitHub's releases list: nothing about the user is sent, the User-Agent is "Daylit/<version>". No self-install:
// Download opens the release page. Same behaviour as mac/Sources/Daylit/Updates.swift (no Homebrew case here).
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Windows.Threading;

namespace Daylit;

sealed partial class Controller {
    public static readonly string? AppVersion = typeof(Controller).Assembly.GetName().Version?.ToString(3);
    static readonly HttpClient updateHttp = new() { Timeout = TimeSpan.FromSeconds(20) };

    /// A newer release, whether the panel shows its line (with What's new open), and what a check from the gear
    /// menu found when there is nothing to show ("You're up to date").
    public UpdateCheck.Available? Update;
    public bool UpdateShown, UpdateExpanded;
    public string? UpdateNote;
    DateTime? updateLastCheck;
    string? updateLastError;
    DateTime? updateLoggedAt;
    DispatcherTimer? updateTimer, updateNoteTimer;

    /// checkUpdates in the config, on by default. Off: no automatic request and no line; the gear menu still checks.
    bool CheckUpdates => Cfg.CheckUpdates ?? true;

    /// A dev build (0.0.0) never asks. The timer fires every hour and checks when the last good answer is a day old,
    /// so turning checkUpdates on later, sleep and failures all catch up without a second timer.
    void StartUpdateChecks() {
        if (UpdateCheck.IsDevBuild(AppVersion)) return;
        updateTimer = new DispatcherTimer(DispatcherPriority.Background, ui) { Interval = UpdateCheck.StartDelay };
        updateTimer.Tick += async (_, _) => {
            updateTimer.Interval = TimeSpan.FromHours(1);
            bool due = updateLastCheck is not DateTime t || DateTime.UtcNow - t >= UpdateCheck.Interval;
            if (CheckUpdates && due) await CheckForUpdates(manual: false);
        };
        updateTimer.Start();
    }

    /// `manual`: from the gear menu. It runs even with checkUpdates off, shows the line even for a version put off
    /// with Not now (What's new open), and says "You're up to date" or that the check failed.
    public async Task CheckForUpdates(bool manual) {
        if (manual) ShowUpdateNote("Checking for updates…", clear: false);
        if (UpdateCheck.IsDevBuild(AppVersion)) {
            if (manual) ShowUpdateNote("This is a development build of Daylit: it does not check for updates.");
            return;
        }
        try {
            var list = await FetchReleases();
            updateLastCheck = DateTime.UtcNow; updateLastError = null; updateLoggedAt = null;
            var a = UpdateCheck.Find(AppVersion, list);
            if (a != null && a.Version != Update?.Version) Log.Write($"update: Daylit {a.Version} is available (running {AppVersion})");
            Update = a;
            bool show = UpdateCheck.ShowLine(a, Settings.UpdateDismissed, CheckUpdates, manual);
            if (manual) {
                UpdateShown = UpdateExpanded = show;
                ShowUpdateNote(show ? null : $"You're up to date: Daylit {AppVersion} is the newest version.");
            } else if (!(UpdateShown && a != null)) UpdateShown = show;   // a line opened from the gear menu stays until Not now
        } catch (Exception e) {
            string msg = "update: check failed (" + Describe(e) + ")";
            var now = DateTime.UtcNow;
            if (HaErrorRule.ShouldLog(msg, updateLastError, updateLoggedAt is DateTime at ? (at - DateTime.UnixEpoch).TotalSeconds : null,
                                      (now - DateTime.UnixEpoch).TotalSeconds)) {
                Log.Write(msg); updateLoggedAt = now;
            }
            updateLastError = msg;
            if (manual) ShowUpdateNote("Couldn't check for updates. Try again later.");
        }
        if (panel?.IsVisible == true) panel.Sync();
    }

    /// After a config reload: checkUpdates off hides the line; on shows it again for a version still waiting.
    void RefreshUpdateLine() {
        UpdateShown = UpdateCheck.ShowLine(Update, Settings.UpdateDismissed, CheckUpdates, manual: false);
        if (!UpdateShown) UpdateExpanded = false;
    }

    public void DownloadUpdate() {
        if (Update is not { } u || !u.Url.StartsWith("https://github.com/", StringComparison.Ordinal)) return;
        try { Process.Start(new ProcessStartInfo(u.Url) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write("update: could not open the release page: " + e.Message); }
    }

    /// Not now: no line for this version until a newer one comes out.
    public void DismissUpdate() {
        if (Update is { } u) { Settings.UpdateDismissed = u.Version; Log.Write($"update: {u.Version} put off"); }
        UpdateShown = UpdateExpanded = false;
        if (panel.IsVisible) panel.Sync();
    }

    public void ToggleUpdateNotes() { UpdateExpanded = !UpdateExpanded; if (panel.IsVisible) panel.Sync(); }

    void ShowUpdateNote(string? s, bool clear = true) {
        updateNoteTimer?.Stop();
        UpdateNote = s;
        if (panel?.IsVisible == true) panel.Sync();
        if (s == null || !clear) return;
        var t = new DispatcherTimer(DispatcherPriority.Background, ui) { Interval = TimeSpan.FromSeconds(10) };
        t.Tick += (_, _) => { t.Stop(); UpdateNote = null; if (panel?.IsVisible == true) panel.Sync(); };
        updateNoteTimer = t;
        t.Start();
    }

    static async Task<List<UpdateCheck.Release>> FetchReleases() {
        using var req = new HttpRequestMessage(HttpMethod.Get, UpdateCheck.ReleasesUrl);
        req.Headers.TryAddWithoutValidation("User-Agent", UpdateCheck.UserAgent(AppVersion));
        req.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
        using var resp = await updateHttp.SendAsync(req);
        if ((int)resp.StatusCode != 200) throw new HttpRequestException("HTTP " + (int)resp.StatusCode);
        return UpdateCheck.Releases(await resp.Content.ReadAsStringAsync()) ?? throw new InvalidDataException("unexpected answer");
    }

    static string Describe(Exception e) => e switch {
        TaskCanceledException => "timed out",
        HttpRequestException h when h.Message.StartsWith("HTTP ") => h.Message,
        _ => e.Message,
    };
}
