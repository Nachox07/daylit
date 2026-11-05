// UI snapshots for visual regression tests: the panel and the on-screen indicator rendered offscreen
// from fixed, made-up state (no monitors, no Home Assistant), light and dark, at 2x.
//   Daylit --render-snapshots <dir>                 write the PNGs
//   Daylit --compare-snapshots <baseline> <dir>     compare, write diff-*.png, exit 1 on a change
// The baselines live in mac/Tests/Snapshots and are recorded on CI (see CONTRIBUTING.md).
import SwiftUI
import AppKit
import DaylitCore

@MainActor enum Snapshots {
    static let scale: CGFloat = 2

    /// Every scene: a name and the view to render.
    static func scenes() -> [(String, AnyView)] {
        func mon(_ id: CGDirectDisplayID, _ label: String, _ level: Double, manual: Bool = false, control: Control = .native) -> Mon {
            var m = Mon(id: id, uuid: "00000000-0000-0000-0000-00000000000\(id)", name: label, label: label, control: control,
                        day: 70, blindDown: 40, night: 20, ha: nil)
            m.level = level; m.available = true; m.readState = .readable; m.manual = manual
            return m
        }
        func model(_ mons: [Mon], source: Source, detail: String = "", sync: Bool = false) -> Daylit {
            let d = Daylit(preview: ())
            d.mons = mons; d.source = source; d.auto = true; d.detail = detail; d.sync = sync
            d.problem = nil; d.builtIn = nil
            d.login = false; d.hasBattery = true; d.lookOn = false; d.pauseOnBattery = true   // not this Mac's own settings
            if sync { d.syncOffsets = SyncOffsets(levels: mons.map { (key: $0.uuid, level: Int($0.level)) }) }
            return d
        }
        let two = [mon(1, "Studio Display", 72), mon(2, "Dell U2723QE", 48)]
        let three = two + [mon(3, "LG 27UK850", 60)]
        let settingsMons = [mon(1, "Studio Display", 72), mon(2, "Dell U2723QE", 48, control: .ddc)]   // the Dell over DDC: its contrast box shows
        return [
            ("panel-two", AnyView(Panel(m: model(two, source: .sun, detail: "Sun · 21.7° above the horizon")))),
            ("panel-two-linked", AnyView(Panel(m: model(two, source: .sun, detail: "Sun · 21.7° above the horizon", sync: true)))),
            ("panel-three-linked", AnyView(Panel(m: model(three, source: .sun, detail: "Sun · 21.7° above the horizon", sync: true)))),
            ("panel-three-partial", AnyView(Panel(m: {
                let d = model(three, source: .sun, detail: "Sun · 21.7° above the horizon", sync: true)
                d.syncOffsets.leave(three[2].uuid)
                return d
            }()))),
            ("panel-one-manual", AnyView(Panel(m: model([mon(1, "LG UltraFine 5K", 60, manual: true)], source: .homeAssistant,
                                                        detail: "Home Assistant · sun 100% · blind 56%")))),
            ("panel-empty", AnyView(Panel(m: model([], source: .off)))),
            ("hud", AnyView(HUDView(label: "Studio Display", value: 72))),
        ].map { ($0.0, AnyView($0.1.background(PanelBackground(cornerRadius: 16)))) } + [
            ("settings-displays", AnyView(SettingsView(m: model(settingsMons, source: .homeAssistant), close: {}, path: settingsFile(), locator: Locator()))),
            ("settings-automatic", AnyView(SettingsView(m: model(settingsMons, source: .homeAssistant), close: {}, path: settingsFile(), locator: Locator(), initialPane: .automatic))),
            ("settings-homeassistant", AnyView(SettingsView(m: model(settingsMons, source: .homeAssistant), close: {}, path: settingsFile(), locator: Locator(), initialPane: .homeAssistant))),
            ("settings-appearance", AnyView(SettingsView(m: model(settingsMons, source: .homeAssistant), close: {}, path: settingsFile(), locator: Locator(), initialPane: .appearance))),
            ("settings-app", AnyView(SettingsView(m: model(settingsMons, source: .homeAssistant), close: {}, path: settingsFile(), locator: Locator(), initialPane: .app))),
        ]
    }

    /// A made-up config for the settings window scene.
    static func settingsFile() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("daylit-snapshot-settings.json")
        try? Data("""
        { "source": "homeAssistant", "location": { "latitude": 51.48, "longitude": 0.00 },
          "homeAssistant": { "url": "http://homeassistant.local:8123", "cover": "cover.office_blind", "lights": "light.office" },
          "monitors": [ { "match": "Studio", "day": 75, "blindDown": 45, "night": 25 },
                        { "match": "U2723QE", "contrast": 60, "homeAssistant": { "day": "input_number.dell_day" } } ],
          "tuning": { "brightness": { "sunDay": 15 }, "theme": { "lightSunAbove": 6 } } }
        """.utf8).write(to: u)
        return u
    }

    static func render(to dir: URL) -> Int32 {
        PanelBackground.plain = true
        SettingsView.fixedNow = Date(timeIntervalSince1970: 1_781_870_400)   // 2026-06-19 12:00 UTC
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, view) in scenes() {
            for dark in [false, true] {
                let file = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                guard let png = image(view, dark: dark) else { FileHandle.standardError.write(Data("failed: \(file.lastPathComponent)\n".utf8)); return 1 }
                do { try png.write(to: file) } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); return 1 }
                print(file.lastPathComponent)
            }
        }
        return 0
    }

    static func image(_ view: AnyView, dark: Bool) -> Data? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let host = NSHostingView(rootView: activeLook(view.environment(\.colorScheme, dark ? .dark : .light)))
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = ActiveWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        window.orderOut(nil)
        return rep.representation(using: .png, properties: [:])
    }

    /// SwiftUI controls in their active look (accent colours), as in the open panel.
    static func activeLook(_ v: some View) -> AnyView {
        #if compiler(>=6.0)
        return AnyView(v.environment(\.controlActiveState, .key).environment(\.appearsActive, true))
        #else
        return AnyView(v.environment(\.controlActiveState, .key))
        #endif
    }

    /// Controls draw their accent colours only in the key window; an offscreen one never is.
    final class ActiveWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    // MARK: compare

    /// A pixel counts as changed when any channel moves more than `channel`; the image fails when more
    /// than `ratio` of its pixels changed (anti-aliasing noise stays under both).
    static let channel = 24, ratio = 0.005

    static func compare(baseline: URL, current: URL) -> Int32 {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: current.path)) ?? []).filter { $0.hasSuffix(".png") && !$0.hasPrefix("diff-") }.sorted()
        let base = Set(((try? fm.contentsOfDirectory(atPath: baseline.path)) ?? []).filter { $0.hasSuffix(".png") })
        if base.isEmpty { print("No baselines in \(baseline.path) yet: nothing to compare (record them, see CONTRIBUTING.md)."); return 0 }
        var failed: [String] = []
        for n in names {
            guard base.contains(n) else { failed.append("\(n): new scene, no baseline"); continue }
            guard let a = bitmap(baseline.appendingPathComponent(n)), let b = bitmap(current.appendingPathComponent(n)) else {
                failed.append("\(n): unreadable"); continue
            }
            if a.pixelsWide != b.pixelsWide || a.pixelsHigh != b.pixelsHigh {
                failed.append("\(n): size \(a.pixelsWide)x\(a.pixelsHigh) → \(b.pixelsWide)x\(b.pixelsHigh)"); continue
            }
            let (changed, diff) = difference(a, b)
            let share = Double(changed) / Double(a.pixelsWide * a.pixelsHigh)
            if share > ratio {
                failed.append(String(format: "%@: %.2f%% of pixels changed", n, share * 100))
                try? diff.representation(using: .png, properties: [:])?.write(to: current.appendingPathComponent("diff-" + n))
            }
        }
        for n in base.subtracting(names) { failed.append("\(n): baseline has no current render (scene removed?)") }
        if failed.isEmpty { print("Snapshots match the baselines (\(names.count) images)."); return 0 }
        print("UI snapshots differ from mac/Tests/Snapshots:")
        failed.forEach { print("  " + $0) }
        print("If the change is intended, re-record the baselines: Actions → build → Run workflow → record snapshots, then commit the downloaded images (CONTRIBUTING.md).")
        return 1
    }

    static func bitmap(_ url: URL) -> NSBitmapImageRep? {
        guard let d = try? Data(contentsOf: url), let r = NSBitmapImageRep(data: d) else { return nil }
        // Normalise to 8-bit RGBA so pixels compare byte for byte.
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: r.pixelsWide, pixelsHigh: r.pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: r.pixelsWide * 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        r.draw(in: NSRect(x: 0, y: 0, width: r.pixelsWide, height: r.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// Changed pixels in red over a faded copy of the new image.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (Int, NSBitmapImageRep) {
        let w = a.pixelsWide, h = a.pixelsHigh
        let diff = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
        guard let pa = a.bitmapData, let pb = b.bitmapData, let pd = diff.bitmapData else { return (w * h, diff) }
        var changed = 0
        for i in 0..<(w * h) {
            let o = i * 4
            var moved = false
            for c in 0..<4 where abs(Int(pa[o + c]) - Int(pb[o + c])) > channel { moved = true; break }
            if moved {
                changed += 1
                pd[o] = 255; pd[o + 1] = 0; pd[o + 2] = 0; pd[o + 3] = 255
            } else {
                pd[o] = pb[o] / 4 + 191; pd[o + 1] = pb[o + 1] / 4 + 191; pd[o + 2] = pb[o + 2] / 4 + 191; pd[o + 3] = 255
            }
        }
        return (changed, diff)
    }
}
