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
            Glyph(name: icon).foregroundStyle(.secondary).frame(width: icon == "ha" ? 15 : 20, height: icon == "ha" ? 15 : nil).frame(width: 20)
            Text(title)
        }
    }
}

/// The Home Assistant logo, from Material Design Icons (`mdi:home-assistant`, Apache-2.0). The name
/// and logo are trademarks of the Open Home Foundation; Daylit uses them only to name what it connects to.
enum HALogo {
    static let path = "M21.8,13H20V21H13V17.67L15.79,14.88L16.5,15C17.66,15 18.6,14.06 18.6,12.9C18.6,11.74 17.66,10.8 16.5,10.8A2.1,2.1 0 0,0 14.4,12.9L14.5,13.61L13,15.13V9.65C13.66,9.29 14.1,8.6 14.1,7.8A2.1,2.1 0 0,0 12,5.7A2.1,2.1 0 0,0 9.9,7.8C9.9,8.6 10.34,9.29 11,9.65V15.13L9.5,13.61L9.6,12.9A2.1,2.1 0 0,0 7.5,10.8A2.1,2.1 0 0,0 5.4,12.9A2.1,2.1 0 0,0 7.5,15L8.21,14.88L11,17.67V21H4V13H2.25C1.83,13 1.42,13 1.42,12.79C1.43,12.57 1.85,12.15 2.28,11.72L11,3C11.33,2.67 11.67,2.33 12,2.33C12.33,2.33 12.67,2.67 13,3L17,7V6H19V9L21.78,11.78C22.18,12.18 22.59,12.59 22.6,12.8C22.6,13 22.2,13 21.8,13M7.5,12A0.9,0.9 0 0,1 8.4,12.9A0.9,0.9 0 0,1 7.5,13.8A0.9,0.9 0 0,1 6.6,12.9A0.9,0.9 0 0,1 7.5,12M16.5,12C17,12 17.4,12.4 17.4,12.9C17.4,13.4 17,13.8 16.5,13.8A0.9,0.9 0 0,1 15.6,12.9A0.9,0.9 0 0,1 16.5,12M12,6.9C12.5,6.9 12.9,7.3 12.9,7.8C12.9,8.3 12.5,8.7 12,8.7C11.5,8.7 11.1,8.3 11.1,7.8C11.1,7.3 11.5,6.9 12,6.9Z"
    static let image: NSImage = {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="\#(path)"/></svg>"#
        let i = NSImage(data: Data(svg.utf8)) ?? NSImage(systemSymbolName: "house", accessibilityDescription: nil)!
        i.isTemplate = true
        return i
    }()
    static let blue = Color(red: 0x18 / 255, green: 0xBC / 255, blue: 0xF2 / 255)
}

/// A symbol name, or "ha" for the Home Assistant logo.
struct Glyph: View {
    let name: String
    var body: some View {
        if name == "ha" { Image(nsImage: HALogo.image).resizable().scaledToFit() }
        else { Image(systemName: name) }
    }
}

/// A System Settings style icon: a white symbol on a small coloured rounded square.
struct Tile: View {
    let icon: String, color: Color
    var body: some View {
        Glyph(name: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .frame(width: icon == "ha" ? 15 : nil, height: icon == "ha" ? 15 : nil)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case displays, automatic, homeAssistant, appearance, app
    var id: String { rawValue }
    var title: String {
        switch self {
        case .displays: "Displays"; case .automatic: "Automatic"; case .homeAssistant: "Home Assistant"
        case .appearance: "Appearance"; case .app: "App"
        }
    }
    var color: Color {
        switch self {
        case .displays: .blue; case .automatic: .orange; case .homeAssistant: HALogo.blue
        case .appearance: .indigo; case .app: .gray
        }
    }
    var icon: String {
        switch self {
        case .displays: "display"; case .automatic: "sun.max"; case .homeAssistant: "ha"
        case .appearance: "circle.lefthalf.filled"; case .app: "gearshape"
        }
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
    let contrastApplies: Bool      // DDC monitor: the contrast box is shown
    var contrast = ""              // empty = not set
    var contrastLoaded = ""        // what the box showed on load: unchanged text keeps the file's value, decimals included
    var nightLights = ""           // "Lights on": empty = not set (night + the room-lights boost)
    var nightLightsLoaded = ""
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
    @State private var daylightSensor = ""
    @State private var tune: [String: String] = [:]   // "group.key" → typed text; empty = the default
    @State private var themeRoom = true
    @State private var opened: ConfigLocation.Opened = .file(nil)
    @State private var error: String? = nil
    @State private var note: String? = nil
    @State private var testing = false
    @State private var locating = false
    let close: () -> Void
    var file: URL? = nil                     // snapshots pass a made-up file
    /// Read each time: turning iCloud Drive on or off moves the file while the window is open.
    var path: URL { file ?? Config.path }
    var height: CGFloat = 600
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
                    .scrollIndicators(Self.fixedNow != nil ? .never : .automatic)   // snapshots: no overlay scrollbar that comes and goes
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
        case .appearance: appearancePane
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
                    if showsNightLights {
                        LabeledContent {
                            HStack(spacing: 6) {
                                TextField("Lights on", text: $d.nightLights, prompt: Text("Not set"))
                                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 64)
                                    .help(Self.nightLightsHelp)
                                Text("%").foregroundStyle(.secondary).frame(width: 16, alignment: .leading)
                            }
                        } label: { Row("Lights on", "lightbulb") }
                    }
                    if d.contrastApplies {
                        LabeledContent {
                            HStack(spacing: 6) {
                                TextField("Contrast", text: $d.contrast, prompt: Text("Not set"))
                                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 64)
                                Text("%").foregroundStyle(.secondary).frame(width: 16, alignment: .leading)
                            }
                        } label: { Row("Contrast", "circle.lefthalf.filled") }
                    }
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
                    Row("Home Assistant", "ha").tag("homeAssistant")
                }
                .pickerStyle(.inline)
            } footer: {
                Text(sourceHint).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Latitude", text: $lat, prompt: Text("51.48"))
                TextField("Longitude", text: $lon, prompt: Text("0.00"))
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
            if source != "off", let chart = brightnessChart {
                Section { chart } header: { Text("When the screens brighten") } footer: {
                    Text("Brightness through today. Drag a handle sideways to choose how high the sun must be for full brightness, and how low for the night level.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Exact values") {
                        ForEach(Tuning.tuningFields.filter { $0.group == "brightness" }) { number($0) }
                    }
                } footer: { tuningFooter(Tuning.tuningFields.filter { $0.group == "brightness" }) }
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
            Section {
                entity("Daylight sensor", "cloud.sun", $daylightSensor, "sensor.solar_power")
                if let s = m.lightStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Clouds") } footer: {
                Text("Optional. Solar panel power, or an outdoor light sensor: on a cloudy day the monitors stay dimmer. Daylit learns what a clear sky reads from the sensor's last 10 days in Home Assistant. Needs a location.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var appPane: some View {
        Form {
            Section {
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
                Toggle(isOn: Binding(get: { m.iCloudOn }, set: { m.setICloud($0); load() })) {
                    Row("Keep settings in iCloud Drive", "icloud")
                }.disabled(iCloudBlocked != nil && !(m.iCloudOn && ConfigLocation.system.override == nil))   // on but signed out: it can still be turned off
            } footer: {
                Text(iCloudFooter).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("config.json") {
                    Button("Open Config File") { m.openConfig() }
                }
            } header: { Text("Advanced") } footer: {
                Text(Config.displayPath + ". Everything in this window is saved there; other keys are kept. How often Daylit checks, when it counts as idle and how long hand-set levels survive a restart are under \"tuning\" → \"timing\" in the file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Why the iCloud switch cannot be turned on here. Snapshots: never, so they look the same on every machine.
    var iCloudBlocked: String? { file != nil ? nil : ConfigLocation.system.iCloudBlocked }

    var iCloudFooter: String {
        let about = "The same settings on every Mac signed in to your iCloud. The Home Assistant token stays on each Mac."
        if let why = iCloudBlocked { return m.iCloudOn ? why + " Daylit uses the settings on this Mac until it is back." : why }
        return m.iCloudNote.map { about + " " + $0 } ?? about
    }

    var appearancePane: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { m.lookOn }, set: { m.setLook($0) })) {
                    Row("Light or dark mode from daylight", "circle.lefthalf.filled")
                }.disabled(source == "off")
                if source == "homeAssistant" {
                    Toggle(isOn: $themeRoom) { Row("Count the blind and the room lights", "lightbulb") }
                }
            } footer: {
                Text(source == "off" ? "Needs the sun or Home Assistant (Automatic)." :
                     "Switches as soon as you turn it on. macOS's own Auto appearance follows only sunset; this also knows your blind and lights.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let curve = sunCurve(["theme.lightSunAbove": ("Light", Color.orange, false), "theme.darkSunBelow": ("Dark", Color.indigo, true)]) {
                Section { curve } header: { Text("Today's sun") } footer: {
                    Text("Drag a line: light mode once the sun is above the orange one, dark below the purple one. Times are for today.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                DisclosureGroup("Exact values") {
                    ForEach(Tuning.appearanceFields.filter { themeRoom && source == "homeAssistant" || $0.group != "theme" || ["lightSunAbove", "darkSunBelow"].contains($0.key) }) { number($0) }
                }
            } footer: {
                tuningFooter(Tuning.appearanceFields)
            }
        }
    }

    func tuningFooter(_ fields: [TuningField]) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Empty fields use the default, shown in grey. Saved in config.json under \"tuning\".")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Reset to Defaults") {
                for f in fields { tune[f.id] = "" }
                if fields.contains(where: { $0.group == "theme" }) { themeRoom = true }
            }
            .controlSize(.small)
            .disabled(fields.allSatisfy { (tune[$0.id] ?? "").isEmpty } && (themeRoom || !fields.contains { $0.group == "theme" }))
        }
    }

    func number(_ f: TuningField) -> some View {
        LabeledContent(f.label) {
            HStack(spacing: 6) {
                TextField(f.label, text: Binding(get: { tune[f.id] ?? "" }, set: { tune[f.id] = $0 }), prompt: Text(Self.fmt(f.defaultValue)))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 64)
                Text(f.unit).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            }
        }
    }

    /// The value a tuning field has in the window: what is typed, or its default.
    func value(_ id: String) -> Double {
        Double((tune[id] ?? "").replacingOccurrences(of: ",", with: ".")) ?? Tuning.allFields.first { $0.id == id }?.defaultValue ?? 0
    }

    /// The brightness through today for the monitors being edited, with the elevations being edited; nil without a location.
    var brightnessChart: BrightnessChart? {
        guard let l = coords, !monitors.isEmpty else { return nil }
        var t = m.config.tuned
        var b = t.brightness ?? .init()
        b.sunNight = value("brightness.sunNight"); b.sunDay = value("brightness.sunDay")
        b.lightsBoost = value("brightness.lightsBoost"); b.lightsBoostSunBelow = value("brightness.lightsBoostSunBelow")
        t.brightness = b
        let snapshot = Self.fixedNow != nil
        return BrightnessChart(latitude: l.0, longitude: l.1, now: Self.now,
                               timeZone: snapshot ? TimeZone(identifier: "UTC")! : .current,   // snapshots: the same on every machine
                               monitors: monitors.map { ChartMonitor(id: $0.id, label: $0.label.isEmpty ? $0.name : $0.label, day: $0.day, blindDown: $0.blindDown, night: $0.night,
                                                                    nightLights: nightLightsValue($0)) },
                               hasBlind: source == "homeAssistant" && !cover.trimmingCharacters(in: .whitespaces).isEmpty,
                               tuning: t, live: snapshot ? nil : m.live,
                               set: { id, v in tune[id] = Self.fmt(Self.keepOrder(id, v, value)) })
    }

    /// Today's sun with draggable lines for the given fields; nil without a location.
    func sunCurve(_ lines: KeyValuePairs<String, (String, Color, Bool)>) -> SunCurve? {
        guard let l = coords else { return nil }
        var tz = TimeZone.current
        if Self.fixedNow != nil { tz = TimeZone(identifier: "UTC")! }   // snapshots: the same on every machine
        return SunCurve(latitude: l.0, longitude: l.1, now: Self.now, timeZone: tz,
                        markers: lines.map { SunMarker(id: $0.key, title: $0.value.0, color: $0.value.1, value: value($0.key), below: $0.value.2) },
                        set: { id, v in tune[id] = Self.fmt(Self.keepOrder(id, v, value)) })
    }

    /// A dragged line stops half a degree short of its partner: full day stays above night, light above dark.
    static func keepOrder(_ id: String, _ v0: Double, _ value: (String) -> Double) -> Double {
        let v = min(max(v0, -18), id == "brightness.sunNight" ? 30 : 60)   // the ranges tuning accepts
        switch id {
        case "brightness.sunDay": return max(v, value("brightness.sunNight") + 0.5)
        case "brightness.sunNight": return min(v, value("brightness.sunDay") - 0.5)
        case "theme.lightSunAbove": return max(v, value("theme.darkSunBelow"))
        case "theme.darkSunBelow": return min(v, value("theme.lightSunAbove"))
        default: return v
        }
    }

    static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

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
                      elev: solarElevation(latitude: l.0, longitude: l.1, at: Self.now), pos: 100, lights: false, tuning: m.config.tuned,
                      light: Self.fixedNow == nil ? m.lightNow ?? 1 : 1)   // with today's clouds; snapshots stay clear
    }

    /// The "Lights on" row shows only with a lights entity: without one the lights count as off.
    var showsNightLights: Bool { source == "homeAssistant" && !lights.trimmingCharacters(in: .whitespaces).isEmpty }
    /// The typed "Lights on" level, while its row shows; nil when empty or not a level.
    func nightLightsValue(_ d: MonitorDraft) -> Double? {
        guard showsNightLights else { return nil }
        // An untouched box keeps the file's value (a decimal stays a decimal), as save does.
        if d.nightLights == d.nightLightsLoaded { return Double(d.nightLights.replacingOccurrences(of: ",", with: ".")) }
        return ContrastRule.parseField(d.nightLights).value.map(Double.init)
    }
    static let nightLightsHelp = "After sunset with the room lights on. Empty keeps Night plus the room-lights boost."

    func caption(_ d: MonitorDraft) -> String {
        var s = coords == nil ? "Set a location to see the level right now." : "Right now is a preview with the blind open; nothing changes until you save."
        if showsNightLights { s += " Lights on: after sunset with the room lights on; empty keeps Night plus the room-lights boost." }
        if d.haLevels { s += " Home Assistant helpers set these levels; these apply only when it cannot be reached." }
        if d.contrastApplies { s += " Contrast is set when the monitor is detected; empty leaves it to the monitor." }
        return s
    }

    func load() {
        opened = ConfigLocation.open(at: path)
        let (c, _) = Config.load(from: path)
        let (src, _) = c.resolvedSource()
        source = c.source ?? (src == .homeAssistant ? "homeAssistant" : src == .sun ? "sun" : "off")
        if let l = c.location { lat = String(format: "%.2f", l.latitude); lon = String(format: "%.2f", l.longitude) } else { lat = ""; lon = "" }
        let h = c.homeAssistant
        haURL = h?.url ?? ""; autoSwitch = h?.autoSwitch ?? ""; sun = h?.sun ?? ""; cover = h?.cover ?? ""; lights = h?.lights ?? ""; daylightSensor = h?.light ?? ""
        tune = (c.tuning?.setValues ?? [:]).mapValues(Self.fmt)
        themeRoom = c.tuning?.theme?.room ?? true
        monitors = m.mons.map { mon in
            let cfg = c.monitor(for: mon.name)
            let ha = cfg?.homeAssistant
            return MonitorDraft(id: mon.uuid, name: mon.name, label: cfg?.label ?? mon.name,
                                day: cfg?.day ?? 70, blindDown: cfg?.blindDown ?? 40, night: cfg?.night ?? 20,
                                haLevels: ha?.day != nil || ha?.blindDown != nil || ha?.night != nil || ha?.nightLights != nil,
                                contrastApplies: mon.control == .ddc, contrast: cfg?.contrast.map { Self.fmt($0) } ?? "",
                                contrastLoaded: cfg?.contrast.map { Self.fmt($0) } ?? "",
                                nightLights: cfg?.nightLights.map { Self.fmt($0) } ?? "",
                                nightLightsLoaded: cfg?.nightLights.map { Self.fmt($0) } ?? "")
        }
        error = opened.blockedReason   // an evicted or unreadable file shows defaults here; save() refuses until it reads
        note = opened.data.map(ConfigText.hasComments) == true ? "Saving removes the comments in config.json." : nil
    }

    func edit() -> SettingsEdit? {
        let blank = lat.trimmingCharacters(in: .whitespaces).isEmpty && lon.trimmingCharacters(in: .whitespaces).isEmpty
        if !blank && coords == nil { error = "Latitude is −90 to 90 and longitude −180 to 180, like 51.48 and 0.00."; return nil }
        if source == "sun" && coords == nil { error = "The sun needs a location: type it or use Locate Me."; return nil }
        if source == "homeAssistant" && haURL.trimmingCharacters(in: .whitespaces).isEmpty { error = "Home Assistant needs its URL."; return nil }
        var values: [String: Double] = [:]
        for f in Tuning.allFields {
            let text = (tune[f.id] ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if text.isEmpty { continue }
            guard let v = Double(text) else { error = "\(f.label) \(f.unit): \"\(text)\" is not a number."; return nil }
            values[f.id] = v
        }
        var mons: [SettingsEdit.Monitor] = []
        for d in monitors {
            var me = SettingsEdit.Monitor(name: d.name, suggestedMatch: CLI.suggestMatch(d.name), label: d.label,
                                         day: Int(d.day.rounded()), blindDown: Int(d.blindDown.rounded()), night: Int(d.night.rounded()))
            if d.contrastApplies {
                let (ok, v, keep) = ContrastRule.parseField(d.contrast, unchangedFrom: d.contrastLoaded)
                if !ok { error = "Contrast for \(d.label) is 0 to 100, or empty to leave it unset."; return nil }
                me.contrastEditable = !keep; me.contrast = v
            }
            if showsNightLights {
                // The same rule as contrast: 0 to 100, or empty for none.
                let (ok, v, keep) = ContrastRule.parseField(d.nightLights, unchangedFrom: d.nightLightsLoaded)
                if !ok { error = "Lights on for \(d.label) is 0 to 100, or empty to keep Night plus the room-lights boost."; return nil }
                me.nightLightsEditable = !keep; me.nightLights = v
            }
            mons.append(me)
        }
        var e = SettingsEdit(source: source, latitude: coords?.0, longitude: coords?.1,
                            monitors: mons,
                            haURL: haURL, autoSwitch: autoSwitch, sun: sun, cover: cover, lights: lights)
        e.light = daylightSensor
        e.tuning = values
        e.themeRoom = themeRoom
        return e
    }

    func save() {
        guard let e = edit() else { return }
        let p = path
        let now = ConfigLocation.open(at: p)
        if let why = now.blockedReason {
            opened = now   // when the file arrives, the next Save reloads the window first
            error = why + "; nothing was saved"
            return
        }
        if now != opened {
            load()
            error = "config.json changed while this window was open. It now shows the new file; check it and save again."
            return
        }
        do {
            let out = try ConfigPatch.apply(e, to: now.data)
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
        let ids = [cover, lights, autoSwitch, sun, daylightSensor].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
