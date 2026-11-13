import AppKit
import DaylitCore

// MARK: command line (see AGENTS.md)

/// `Daylit --list-monitors` / `--check-config`: JSON on stdout, exit 0 when fine, 1 when something needs fixing.
@MainActor enum CLI {
    static let help = """
        Daylit — monitor brightness from the sun or Home Assistant.
          Daylit                  start the menu-bar app
          Daylit --list-monitors  connected monitors as JSON (use "match" in config.json)
          Daylit --check-config   validate \(Config.path.path)
          Daylit --render-snapshots <dir>               UI snapshots for the visual tests
          Daylit --compare-snapshots <baseline> <dir>   compare them; exit 1 on a change
          Daylit --render-chart-frames <dir> [dark]     frames of the brightness chart animation (docs)
        Run it from the app bundle: ~/Applications/Daylit.app/Contents/MacOS/Daylit --list-monitors
        """

    static func run(_ args: [String]) -> Int32? {
        // Launch Services may pass -psn_… or -NSDocumentRevisionsDebugMode; only our flags count.
        guard let cmd = args.first?.lowercased(), ["--list-monitors", "--check-config", "--render-snapshots", "--compare-snapshots", "--render-chart-frames", "--help", "-h"].contains(cmd) else { return nil }
        _ = NSApplication.shared   // NSScreen needs the app object
        switch cmd {
        case "--list-monitors": return emit(listMonitors(), 0)
        case "--check-config": let (j, ok) = checkConfig(); return emit(j, ok ? 0 : 1)
        case "--render-snapshots":
            guard args.count >= 2 else { print(help); return 2 }
            return Snapshots.render(to: URL(fileURLWithPath: args[1]))
        case "--render-chart-frames":
            guard args.count >= 2 else { print(help); return 2 }
            return Snapshots.chartFrames(to: URL(fileURLWithPath: args[1]), dark: args.count > 2 && args[2] == "dark")
        case "--compare-snapshots":
            guard args.count >= 3 else { print(help); return 2 }
            return Snapshots.compare(baseline: URL(fileURLWithPath: args[1]), current: URL(fileURLWithPath: args[2]))
        default: print(help); return 0
        }
    }

    static func emit(_ obj: Any, _ code: Int32) -> Int32 {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: d, encoding: .utf8) { print(s) }
        return code
    }

    /// A short, stable part of the name: the model ("AW3821DW") rather than the brand.
    static func suggestMatch(_ name: String) -> String {
        name.split(separator: " ").last { t in t.contains(where: \.isNumber) && t.contains(where: \.isLetter) }.map(String.init) ?? name
    }

    static func listMonitors() -> [String: Any] {
        let (cfg, _) = Config.load()
        DDC.configure(cfg.ddcTool)
        var out: [[String: Any]] = []
        for s in NSScreen.screens {
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
            let entry = cfg.monitors?.first { s.localizedName.localizedCaseInsensitiveContains($0.match) }
            var control = "none", level: Int? = nil
            if builtIn { control = "native (manual slider only; automatic mode leaves it to macOS)"; level = Native.get(id) }
            else {
                let forced = entry?.control
                if forced != "ddc", let v = Native.get(id) { control = "native"; level = v }
                else if forced != "native", DDC.available { control = "ddc"; level = DDC.get(uuid) }
                else if forced == "native" { control = "native" }
                else { control = "none (\(DDC.hint))" }
            }
            var o: [String: Any] = ["name": s.localizedName, "match": suggestMatch(s.localizedName), "uuid": uuid,
                                    "builtIn": builtIn, "control": control, "controllable": !builtIn && level != nil]
            o["brightness"] = level ?? NSNull()
            o["configuredAs"] = entry.map { ($0.label ?? $0.match) as Any } ?? NSNull()
            out.append(o)
        }
        return ["monitors": out]
    }

    static func checkConfig() -> ([String: Any], Bool) {
        let exists = FileManager.default.fileExists(atPath: Config.path.path)
        let (cfg, err) = Config.load()
        let (src, srcErr) = cfg.resolvedSource()
        var problems: [String] = [], notes: [String] = []
        if let err { problems.append(err) }
        if let srcErr { problems.append(srcErr) }
        if let note = DDC.configure(cfg.ddcTool) { notes.append(note) }
        let names = externalScreens().map(\.name)
        var monitors: [[String: Any]] = []
        for m in cfg.monitors ?? [] {
            let hit = names.first { $0.localizedCaseInsensitiveContains(m.match) }
            if m.homeAssistant != nil && src != .homeAssistant {
                problems.append("monitor \"\(m.match)\" has homeAssistant entities but the source is \(src)")
            }
            if let c = m.control, !["native", "ddc", "auto"].contains(c) {
                problems.append("monitor \"\(m.match)\": control must be native, ddc or auto")
            }
            if (m.nightLights != nil || m.homeAssistant?.nightLights != nil) && (src != .homeAssistant || (cfg.homeAssistant?.lights ?? "").isEmpty) {
                notes.append("monitor \"\(m.match)\": nightLights needs homeAssistant.lights; without it the lights count as off")
            }
            if hit == nil { notes.append("monitor \"\(m.match)\" is not connected right now (fine if it is used elsewhere)") }
            monitors.append(["match": m.match, "label": (m.label ?? NSNull()) as Any, "connected": (hit ?? NSNull()) as Any])
        }
        if !exists { notes.append("no config.json: Daylit runs with sliders and brightness keys only") }
        if (cfg.monitors ?? []).contains(where: { $0.control != "native" }) || cfg.monitors == nil, !DDC.available {
            notes.append(DDC.missingNote)
        }
        var result: [String: Any] = ["ok": problems.isEmpty, "path": Config.displayPath, "exists": exists,
                                     "source": "\(src)", "problems": problems, "notes": notes, "monitors": monitors,
                                     // the numbers in use, defaults included
                                     "tuning": Dictionary(uniqueKeysWithValues: Tuning.allFields.map { f in
                                         (f.id, cfg.tuned.setValues[f.id] ?? f.defaultValue) }).merging(["theme.room": cfg.tuned.room ? 1 : 0]) { a, _ in a }]
        if src == .homeAssistant, let ha = cfg.homeAssistant {
            let name = ha.tokenName ?? "daylit-home-assistant"
            let stored = HAClient.tokenStored(name)   // presence only, never read or printed
            if !stored { notes.append("no Home Assistant token in the keychain as \"\(name)\" (see README; the user adds it)") }
            if let u = ha.url, Config.isCleartextToNonLocal(u) {
                notes.append("homeAssistant.url is http:// to a host outside the local network: the token travels unencrypted; use https://")
            }
            result["notes"] = notes
            result["homeAssistant"] = ["url": (ha.url ?? NSNull()) as Any, "tokenName": name, "tokenStored": stored]
        } else {
            result["homeAssistant"] = NSNull()
        }
        return (result, problems.isEmpty)
    }
}
