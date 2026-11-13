// Telling the user a newer Daylit is out (DaylitCore.UpdateCheck). Once a little after start, then once a day,
// one GET to GitHub's releases list: nothing about the user is sent, the User-Agent is "Daylit/<version>".
// No self-install: Download opens the release page (Homebrew installs get the brew command).
import AppKit
import DaylitCore

extension Daylit {
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    /// checkUpdates in the config, on by default. Off: no automatic request and no line; the gear menu still checks.
    var checkUpdates: Bool { config.checkUpdates ?? true }
    /// The version put off with Not now (this Mac only): no line for it, only for a newer one.
    var updateDismissed: String? { UserDefaults.standard.string(forKey: "updateDismissed") }

    /// A dev build (0.0.0) never asks. The loop wakes every hour and checks when the last good answer is a day old,
    /// so turning checkUpdates on later, sleep and failures all catch up without a second timer.
    func startUpdateChecks() {
        guard !UpdateCheck.isDevBuild(Self.appVersion) else { log("update: dev build, no update checks"); return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UpdateCheck.startDelay * 1_000_000_000))
            while !Task.isCancelled {
                guard let self else { return }
                let due = self.updateLastCheck.map { Date().timeIntervalSince($0) >= UpdateCheck.interval } ?? true
                if self.checkUpdates && due { await self.checkForUpdates(manual: false) }
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
    }

    /// `manual`: from the gear menu. It runs even with checkUpdates off, shows the line even for a version put off
    /// with Not now (What's new open), and says "You're up to date" or that the check failed.
    func checkForUpdates(manual: Bool) async {
        if manual { showUpdateNote("Checking for updates…", clearAfter: nil) }
        guard !UpdateCheck.isDevBuild(Self.appVersion) else {
            if manual { showUpdateNote("This is a development build of Daylit: it does not check for updates.") }
            return
        }
        do {
            let list = try await Self.fetchReleases()
            updateLastCheck = Date(); updateLastError = nil; updateLoggedAt = nil
            let a = UpdateCheck.available(running: Self.appVersion, releases: list)
            if let a, a.version != update?.version { Log.write("update: Daylit \(a.version) is available (running \(Self.appVersion ?? "?"))") }
            update = a
            let show = UpdateCheck.showLine(a, dismissed: updateDismissed, checkUpdates: checkUpdates, manual: manual)
            if manual {
                updateShown = show; updateExpanded = show
                if show { showUpdateNote(nil) } else { showUpdateNote("You're up to date: Daylit \(Self.appVersion ?? "") is the newest version.") }
            } else if !(updateShown && a != nil) {   // a line opened from the gear menu stays until Not now
                updateShown = show
            }
        } catch {
            let msg = "update: check failed (\(Self.describe(error)))"
            let now = Date()
            if HAErrorRule.shouldLog(message: msg, lastMessage: updateLastError, lastLogged: updateLoggedAt?.timeIntervalSince1970,
                                     now: now.timeIntervalSince1970) {
                Log.write(msg); updateLoggedAt = now
            }
            updateLastError = msg
            if manual { showUpdateNote("Couldn't check for updates. Try again later.") }
        }
    }

    /// After a config reload: checkUpdates off hides the line; on shows it again for a version still waiting.
    func refreshUpdateLine() {
        updateShown = UpdateCheck.showLine(update, dismissed: updateDismissed, checkUpdates: checkUpdates, manual: false)
        if !updateShown { updateExpanded = false }
    }

    func downloadUpdate() {
        guard let u = update, let url = URL(string: u.url), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    func copyBrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UpdateCheck.brewCommand, forType: .string)
    }

    /// Not now: no line for this version until a newer one comes out.
    func dismissUpdate() {
        if let v = update?.version { UserDefaults.standard.set(v, forKey: "updateDismissed"); Log.write("update: \(v) put off") }
        updateShown = false; updateExpanded = false
    }

    func showUpdateNote(_ s: String?, clearAfter seconds: Double? = 10) {
        updateNoteClear?.cancel()
        updateNote = s
        guard s != nil, let seconds else { return }
        updateNoteClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.updateNote = nil }
        }
    }

    static let updateSession = URLSession(configuration: .ephemeral)   // no cookies or cache kept

    enum FetchError: Error { case http(Int), notReleases }

    static func fetchReleases() async throws -> [UpdateCheck.Release] {
        var r = URLRequest(url: URL(string: UpdateCheck.releasesURL)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.setValue(UpdateCheck.userAgent(version: appVersion), forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await updateSession.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw FetchError.http(code) }
        guard let list = UpdateCheck.releases(json: data) else { throw FetchError.notReleases }
        return list
    }

    static func describe(_ e: Error) -> String {
        switch e {
        case FetchError.http(let c): return "HTTP \(c)"
        case FetchError.notReleases: return "unexpected answer"
        default: return e.localizedDescription
        }
    }
}
