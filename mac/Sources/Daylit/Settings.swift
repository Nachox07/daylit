// The settings window: source, location, levels per monitor and Home Assistant, saved into
// config.json without touching anything else in it (ConfigPatch).
import SwiftUI
import AppKit
import CoreLocation
import DaylitCore

enum LocateResult { case success(CLLocationCoordinate2D), failure(String) }

/// A label whose icon has a fixed width, so the texts of a list line up whatever the symbol.
struct Row: View {
    let title: String, icon: String
    init(_ title: String, _ icon: String) { self.title = title; self.icon = icon }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            Text(title)
        }
    }
}

/// A System Settings style icon: a white symbol on a small coloured rounded square.
struct Tile: View {
    let icon: String, color: Color
    var body: some View {
        Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case displays, automatic, homeAssistant, app
    var id: String { rawValue }
    var title: String {
        switch self { case .displays: "Displays"; case .automatic: "Automatic"; case .homeAssistant: "Home Assistant"; case .app: "App" }
    }
    var color: Color {
        switch self { case .displays: .blue; case .automatic: .orange; case .homeAssistant: .teal; case .app: .gray }
    }
    var icon: String {
        switch self { case .displays: "display"; case .automatic: "sun.max"; case .homeAssistant: "house"; case .app: "gearshape" }
    }
}

/// One "where am I" request. Asks for permission only when the button is clicked; nothing is tracked.
@MainActor final class Locator: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var done: ((LocateResult) -> Void)?
    private var request = 0

    func locate(_ done: @escaping (LocateResult) -> Void) {
        self.done = done
        request += 1
        let mine = request
        // Never leave the button waiting: no answer in 20 s (a prompt left open, no Wi-Fi) is a failure.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.request == mine else { return }
            self.finish(.failure("No location after 20 seconds. Check the permission prompt, or type the coordinates."))
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: finish(.failure(Locator.denied))
        default: manager.requestLocation()
        }
    }

    nonisolated static let denied = "Location is off for Daylit. Allow it in System Settings → Privacy & Security → Location Services, or type the coordinates."

    private func finish(_ r: LocateResult) { done?(r); done = nil }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let st = m.authorizationStatus
        Task { @MainActor in
            guard self.done != nil else { return }
            switch st {
            case .notDetermined: break
            case .denied, .restricted: self.finish(.failure(Locator.denied))
            default: self.manager.requestLocation()
            }
        }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        Task { @MainActor in self.finish(.success(c)) }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        let msg = (error as NSError).code == CLError.denied.rawValue ? Locator.denied : "Could not find your location. Type the coordinates instead."
        Task { @MainActor in self.finish(.failure(msg)) }
    }
}

struct MonitorDraft: Identifiable {
    let id: String                 // display uuid
    let name: String
    var label: String
    var day, blindDown, night: Double
    let haLevels: Bool             // Home Assistant helpers set these levels
}

struct SettingsView: View {
    @ObservedObject var m: Daylit

    @State private var source = "off"
    @State private var lat = ""
    @State private var lon = ""
    @State private var monitors: [MonitorDraft] = []
    @State private var haURL = ""
    @State private var autoSwitch = ""
    @State private var sun = ""
    @State private var cover = ""
    @State private var lights = ""
    @State private var opened: Data? = nil
    @State private var error: String? = nil
    @State private var note: String? = nil
    @State private var testing = false
    @State private var locating = false
    let close: () -> Void
    var path: URL = Config.path              // snapshots pass a made-up file
    var height: CGFloat = 540
    /// Snapshots: a fixed time, so "Sun now" and the previews do not change between runs.
    nonisolated(unsafe) static var fixedNow: Date?
    static var now: Date { fixedNow ?? Date() }
    @ObservedObject var locator: Locator   // made by the caller: CI's older Swift rejects a main-actor @State default

    @State private var pane: SettingsPane? = nil
    var initialPane: SettingsPane = .displays   // snapshots pick one

    var current: SettingsPane { pane ?? initialPane }
    var panes: [SettingsPane] { SettingsPane.allCases.filter { $0 != .homeAssistant || source == "homeAssistant" } }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { current }, set: { pane = $0 })) {
                ForEach(panes) { p in
                    Label { Text(p.title) } icon: { Tile(icon: p.icon, color: p.color) }.tag(p)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(.regularMaterial)
            .padding(.top, 28)      // below the window buttons
            .frame(width: 215)
            .background(.regularMaterial)
            Divider()
            VStack(spacing: 0) {
                Text(current.title).font(.headline).frame(maxWidth: .infinity).frame(height: 28)
                detail.formStyle(.grouped)
                footer
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea(edges: .top)
        .frame(width: 760, height: height)
        .onAppear(perform: load)
        .onChange(of: source) { _, s in if s != "homeAssistant" && current == .homeAssistant { pane = .automatic } }
    }

    @ViewBuilder var detail: some View {
        switch current {
        case .displays: displaysPane
        case .automatic: automaticPane
        case .homeAssistant: homeAssistantPane
        case .app: appPane
        }
    }

    var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).lineLimit(2) }
            else if let note { Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            Button("Save", action: save).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    var displaysPane: some View {
        Form {
            if monitors.isEmpty {
                Section {
                    Label("No external monitor connected. Plug one in to set its levels.", systemImage: "display.trianglebadge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach($monitors) { $d in
                Section {
                    TextField("Name", text: $d.label)
                    level("Day", "sun.max", $d.day)
                    level("Blind closed", "blinds.horizontal.closed", $d.blindDown)
                    level("Night", "moon", $d.night)
                    if let now = rightNow(d) {
                        LabeledContent("Right now") {
                            Text("\(now)%").font(.title3.weight(.semibold)).monospacedDigit()
                        }
                    }
                } header: {
                    Label(d.name, systemImage: "display")
                } footer: {
                    Text(caption(d)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var automaticPane: some View {
        Form {
            Section {
                Picker("Brightness follows", selection: $source) {
                    Row("Nothing, sliders only", "slider.horizontal.3").tag("off")
                    Row("The sun", "sun.max").tag("sun")
                    Row("Home Assistant", "house").tag("homeAssistant")
                }
                .pickerStyle(.inline)
            } footer: {
                Text(sourceHint).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Latitude", text: $lat, prompt: Text("36.72"))
                TextField("Longitude", text: $lon, prompt: Text("-4.42"))
                HStack {
                    Button(action: locate) { Label(locating ? "Locating…" : "Locate Me", systemImage: "location") }.disabled(locating)
                    Spacer()
                    if let l = coords {
                        Label(String(format: "Sun now %.1f°", solarElevation(latitude: l.0, longitude: l.1, at: Self.now)), systemImage: "sun.horizon")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Location") } footer: {
                Text("City level is enough; Daylit saves two decimals (about 1 km) and computes the sun on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var homeAssistantPane: some View {
        Form {
            Section {
                TextField("URL", text: $haURL, prompt: Text("http://homeassistant.local:8123"))
                HStack {
                    Button(action: test) { Label(testing ? "Testing…" : "Test Connection", systemImage: "antenna.radiowaves.left.and.right") }
                        .disabled(testing || haURL.isEmpty)
                    Button { TokenWindow.show(m) } label: { Label("Token…", systemImage: "key") }
                    Spacer()
                }
            } header: { Text("Connection") }
            Section {
                entity("Blind", "blinds.vertical.open", $cover, "cover.office_blind")
                entity("Lights", "lightbulb", $lights, "light.office")
                entity("Automatic switch", "switch.2", $autoSwitch, "input_boolean.daylit_auto")
                entity("Sun", "sun.max", $sun, "sun.sun")
            } header: { Text("Room") } footer: {
                Text("All optional. Entity ids as shown in Home Assistant → Settings → Entities. Per-monitor helpers stay in the config file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var appPane: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { m.lookOn }, set: { m.setLook($0) })) {
                    Row("Light or dark mode from daylight", "circle.lefthalf.filled")
                }.disabled(source == "off")
                if m.hasBattery {
                    Toggle(isOn: Binding(get: { m.pauseOnBattery }, set: { m.setPause($0) })) {
                        Row("Pause on battery", "battery.50")
                    }
                }
                Toggle(isOn: Binding(get: { m.login }, set: { m.setLogin($0) })) {
                    Row("Open at login", "power")
                }
            } footer: {
                Text("These apply right away.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("config.json") {
                    Button("Open Config File") { m.openConfig() }
                }
            } header: { Text("Advanced") } footer: {
                Text(Config.displayPath + ". Everything in this window is saved there; other keys are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func entity(_ title: String, _ icon: String, _ v: Binding<String>, _ example: String) -> some View {
        TextField(text: v, prompt: Text(example)) { Row(title, icon) }
    }

    var sourceHint: String {
        switch source {
        case "sun": return "Brighter by day, dimmer at night, from your location."
        case "homeAssistant": return "The sun, a blind and the room lights from Home Assistant. With a location, the sun takes over when Home Assistant is down."
        default: return "Sliders and keyboard shortcuts only."
        }
    }

    func level(_ title: String, _ icon: String, _ v: Binding<Double>) -> some View {
        HStack {
            Row(title, icon).frame(width: 140, alignment: .leading)
            Slider(value: v, in: 0...100).accessibilityLabel(title)
            Text("\(Int(v.wrappedValue.rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
        }
    }

    var coords: (Double, Double)? {
        guard let a = Double(lat.replacingOccurrences(of: ",", with: ".")), let b = Double(lon.replacingOccurrences(of: ",", with: ".")),
              (-90...90).contains(a), (-180...180).contains(b) else { return nil }
        return (a, b)
    }

    /// What the levels give right now with the blind open and the lights off: a preview, nothing is set.
    func rightNow(_ d: MonitorDraft) -> Int? {
        guard let l = coords else { return nil }
        return target(day: d.day, blindDown: d.blindDown, night: d.night,
                      elev: solarElevation(latitude: l.0, longitude: l.1, at: Self.now), pos: 100, lights: false)
    }

    func caption(_ d: MonitorDraft) -> String {
        var s = coords == nil ? "Set a location to see the level right now." : "Right now is a preview with the blind open; nothing changes until you save."
        if d.haLevels { s += " Home Assistant helpers set these levels; these apply only when it cannot be reached." }
        return s
    }

    func load() {
        opened = try? Data(contentsOf: path)
        let (c, _) = Config.load(from: path)
        let (src, _) = c.resolvedSource()
        source = c.source ?? (src == .homeAssistant ? "homeAssistant" : src == .sun ? "sun" : "off")
        if let l = c.location { lat = String(format: "%.2f", l.latitude); lon = String(format: "%.2f", l.longitude) } else { lat = ""; lon = "" }
        let h = c.homeAssistant
        haURL = h?.url ?? ""; autoSwitch = h?.autoSwitch ?? ""; sun = h?.sun ?? ""; cover = h?.cover ?? ""; lights = h?.lights ?? ""
        monitors = m.mons.map { mon in
            let cfg = c.monitors?.first { mon.name.localizedCaseInsensitiveContains($0.match) }
            let ha = cfg?.homeAssistant
            return MonitorDraft(id: mon.uuid, name: mon.name, label: cfg?.label ?? mon.name,
                                day: cfg?.day ?? 70, blindDown: cfg?.blindDown ?? 40, night: cfg?.night ?? 20,
                                haLevels: ha?.day != nil || ha?.blindDown != nil || ha?.night != nil)
        }
        error = nil
        note = opened.map(ConfigText.hasComments) == true ? "Saving removes the comments in config.json." : nil
    }

    func edit() -> SettingsEdit? {
        let blank = lat.trimmingCharacters(in: .whitespaces).isEmpty && lon.trimmingCharacters(in: .whitespaces).isEmpty
        if !blank && coords == nil { error = "Latitude is −90 to 90 and longitude −180 to 180, like 36.72 and -4.42."; return nil }
        if source == "sun" && coords == nil { error = "The sun needs a location: type it or use Locate Me."; return nil }
        if source == "homeAssistant" && haURL.trimmingCharacters(in: .whitespaces).isEmpty { error = "Home Assistant needs its URL."; return nil }
        return SettingsEdit(source: source, latitude: coords?.0, longitude: coords?.1,
                            monitors: monitors.map { .init(name: $0.name, suggestedMatch: CLI.suggestMatch($0.name), label: $0.label,
                                                           day: Int($0.day.rounded()), blindDown: Int($0.blindDown.rounded()), night: Int($0.night.rounded())) },
                            haURL: haURL, autoSwitch: autoSwitch, sun: sun, cover: cover, lights: lights)
    }

    func save() {
        guard let e = edit() else { return }
        let p = path
        let now = try? Data(contentsOf: p)
        if now != opened {
            load()
            error = "config.json changed while this window was open. It now shows the new file; check it and save again."
            return
        }
        do {
            let out = try ConfigPatch.apply(e, to: now)
            try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: p, options: .atomic)
            Log.write("settings: saved config.json (source=\(e.source))")
            m.reload()
            close()
        } catch ConfigEditError.invalid(let why) {
            error = why.replacingOccurrences(of: "config.json: ", with: "")
        } catch ConfigEditError.notAnObject {
            error = "config.json is not a JSON object; fix it with Open Config File."
        } catch {
            self.error = "config.json could not be read or saved: \(error.localizedDescription)"
        }
    }

    func locate() {
        locating = true; error = nil
        locator.locate { r in
            locating = false
            switch r {
            case .success(let c): lat = String(format: "%.2f", c.latitude); lon = String(format: "%.2f", c.longitude); note = "Location found."
            case .failure(let msg): error = msg
            }
        }
    }

    /// Checks the URL and the stored token, then that each entity typed here exists.
    func test() {
        let ids = [cover, lights, autoSwitch, sun].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let bad = ids.first(where: { !Config.isEntityId($0) }) { error = "\"\(bad)\" is not an entity id like light.office."; return }
        var ha = m.config.homeAssistant ?? HAConfig()
        ha.url = haURL.trimmingCharacters(in: .whitespaces)
        let template = ids.isEmpty ? "ok" : ids.map { "{{ '\($0)' if states('\($0)') in ['unknown', 'unavailable'] else '' }}" }.joined(separator: " ")
        testing = true; error = nil; note = nil
        Task { @MainActor in
            let r = await HAClient.call(ha, "/api/template", ["template": template])
            testing = false
            switch r {
            case .success(let d):
                let missing = (String(data: d, encoding: .utf8) ?? "").split(separator: " ").map(String.init).filter { $0 != "ok" }
                if missing.isEmpty { note = "Connected to Home Assistant." }
                else { error = "Connected, but not found or unavailable: " + missing.joined(separator: ", ") }
            case .failure(let f):
                error = HAClient.describe(f, ha) + (HAClient.lastCause.map { " (\($0))" } ?? "")
            }
        }
    }
}

@MainActor enum SettingsWindow {
    static var window: NSWindow?
    static func show(_ model: Daylit) {
        StatusController.shared?.close()
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Daylit Settings"; w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden   // the pane's own title sits there
        w.contentViewController = NSHostingController(rootView: SettingsView(m: model, close: { window?.close() }, locator: Locator()))
        w.center(); window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in window = nil }
        }
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
}
