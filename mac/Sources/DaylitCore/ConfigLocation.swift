// Where config.json lives: ~/.config/daylit, or iCloud Drive when "Keep settings in iCloud Drive" is on,
// so every Mac signed in to the same iCloud reads the same file. DAYLIT_CONFIG wins over both.
// Moving the file in and out of iCloud Drive and noticing a change from another Mac are here, so the
// tests can run them on plain folders. No iCloud API is used: iCloud Drive is a folder in the home
// folder, and the app needs no iCloud entitlement for it.
import Foundation

public struct ConfigLocation {
    /// UserDefaults key for the switch. It cannot live in the file it moves.
    public static let defaultsKey = "configInICloud"

    public let home: URL
    /// DAYLIT_CONFIG, when set.
    public let override: URL?

    public init(home: URL, environment: [String: String] = [:]) {
        self.home = home
        if let p = environment["DAYLIT_CONFIG"], !p.isEmpty { override = URL(fileURLWithPath: p) } else { override = nil }
    }

    /// This user's home folder and environment.
    public static var system: ConfigLocation {
        ConfigLocation(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
    }

    public var local: URL { home.appendingPathComponent(".config/daylit/config.json") }
    /// The local file as it was when this Mac adopted the iCloud copy.
    public var backup: URL { local.deletingLastPathComponent().appendingPathComponent("config.local-backup.json") }
    public var iCloudDrive: URL { home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true) }
    public var iCloud: URL { iCloudDrive.appendingPathComponent("Daylit/config.json") }

    /// iCloud Drive is on for this user when its folder exists.
    public var iCloudAvailable: Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: iCloudDrive.path, isDirectory: &dir) && dir.boolValue
    }

    /// Why the switch cannot be used here, or nil.
    public var iCloudBlocked: String? {
        if override != nil { return "DAYLIT_CONFIG is set, so Daylit uses that file." }
        if !iCloudAvailable { return "iCloud Drive is not turned on for this Mac (System Settings → Apple Account → iCloud)." }
        return nil
    }

    /// The file to read and write. With the switch on but iCloud Drive gone (signed out), the local file.
    public func path(useICloud: Bool) -> URL {
        if let override { return override }
        return useICloud && iCloudAvailable ? iCloud : local
    }

    // MARK: the file's state

    public enum FileState: Equatable { case missing, present, evicted }

    /// The name iCloud Drive gives a file it has removed from this Mac to save space: `.config.json.icloud`.
    public static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    public static func state(of url: URL) -> FileState {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return .present }
        return fm.fileExists(atPath: placeholder(for: url).path) ? .evicted : .missing
    }

    /// What changes when the file does: iCloud replaces it by renaming a new one over it, so the inode
    /// changes even when the time and size happen to stay the same.
    public struct Stamp: Equatable {
        public var state: FileState
        public var modified: Date?
        public var size: Int?
        public var inode: Int?
    }

    /// A stat only: it never reads the file, so it never makes iCloud download it.
    public static func stamp(of url: URL) -> Stamp {
        let s = state(of: url)
        guard s == .present, let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return Stamp(state: s) }
        return Stamp(state: s, modified: a[.modificationDate] as? Date, size: (a[.size] as? NSNumber)?.intValue,
                     inode: (a[.systemFileNumber] as? NSNumber)?.intValue)
    }

    // MARK: turning the switch on and off

    public enum MoveError: Error, Equatable {
        case noICloudDrive
        case overridden
        /// The iCloud copy is not on this Mac yet; iCloud is downloading it.
        case notDownloaded
    }

    public enum Enabled: Equatable {
        /// First Mac: the local file is now the iCloud copy.
        case copiedLocal
        /// Nothing to copy: the file is created in iCloud Drive on the first save.
        case empty
        /// Another Mac put its settings there first. `backedUp`: the local file was different and is
        /// kept as config.local-backup.json. `downloading`: the copy is still on its way to this Mac.
        case adopted(backedUp: Bool, downloading: Bool)
    }

    /// Turns the switch on. The caller saves the switch only when this does not throw.
    public func moveToICloud() throws -> Enabled {
        if override != nil { throw MoveError.overridden }
        guard iCloudAvailable else { throw MoveError.noICloudDrive }
        let fm = FileManager.default
        let there = Self.state(of: iCloud)
        let mine = try? Data(contentsOf: local)
        if there == .missing {
            guard let mine else { return .empty }
            try fm.createDirectory(at: iCloud.deletingLastPathComponent(), withIntermediateDirectories: true)
            try mine.write(to: iCloud, options: .atomic)
            return .copiedLocal
        }
        // An evicted copy cannot be compared without waiting for it: keep the local file to be safe.
        var backedUp = false
        if let mine, there == .evicted || (try? Data(contentsOf: iCloud)) != mine {
            try mine.write(to: backup, options: .atomic)
            backedUp = true
        }
        return .adopted(backedUp: backedUp, downloading: there == .evicted)
    }

    public enum Disabled: Equatable {
        /// The iCloud copy is now the local file too.
        case copiedBack
        /// No iCloud copy: the local file is used as it is.
        case nothingThere
    }

    /// Turns the switch off: this Mac keeps the settings it has now. The iCloud copy is left alone for the other Macs.
    public func moveToLocal() throws -> Disabled {
        if override != nil { throw MoveError.overridden }
        switch Self.state(of: iCloud) {
        case .missing: return .nothingThere
        case .evicted: throw MoveError.notDownloaded
        case .present:
            let d = try Data(contentsOf: iCloud)
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: local, options: .atomic)
            return .copiedBack
        }
    }
}

extension Config {
    /// Loading again after the file changed, possibly on another Mac. Unlike `load`, a file that cannot
    /// be used right now (not valid JSON, half written, or evicted by iCloud and still downloading)
    /// keeps the last config that loaded, with the problem to show. `kept` says the old one is still in use.
    public static func reload(from url: URL, lastGood: Config?) -> (config: Config, problem: String?, kept: Bool) {
        switch ConfigLocation.state(of: url) {
        case .missing:
            return (Config(), nil, false)
        case .evicted:
            return (lastGood ?? Config(), "config.json is still downloading from iCloud Drive", lastGood != nil)
        case .present:
            guard let d = try? Data(contentsOf: url) else {
                return (lastGood ?? Config(), "config.json could not be read", lastGood != nil)
            }
            let (c, err) = parse(d)
            if let c { return (c, err, false) }
            guard let lastGood else { return (Config(), err, false) }
            return (lastGood, (err ?? "config.json is not valid") + ". Daylit keeps the last settings that loaded", true)
        }
    }
}
