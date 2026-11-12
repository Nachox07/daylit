// Settings → Automatic: how bright a monitor gets through today. Time across, brightness up; one line
// with the blind open and one with it closed; two handles, each one sun height (DaylitCore.Chart), with
// both of its crossings draggable; and "How Daylit decides, right now". Snapshots draw it from fixed state.
import SwiftUI
import AppKit
import DaylitCore

/// What the monitors see right now, from the last tick: nil fields when Daylit has no reading.
struct LiveInputs: Equatable {
    var elev: Double? = nil     // the sun's elevation the tick used (Home Assistant's when it has one)
    var pos: Double?            // blind position 0…100; nil without a blind
    var lights = false
    var light = 1.0             // the cloud cap on the sun's share (1: clear or no sensor)
    var levels: [String: [Double]] = [:]   // Home Assistant's day / blind closed / night per monitor uuid
    var offsets: [String: (value: Int, weight: Double)] = [:]   // a hand-set distance in effect, per monitor uuid
    var linked: [String: Int] = [:]   // linked monitors that follow another: the level they land on
    var leader = ""                   // the monitor they follow
    var applying = true               // false: Automatic is off or this Mac is idle, so nothing is being set
    var lightsUsed: [String: Bool] = [:]   // the room lights each monitor's target used (the sun fallback keeps them for nightLights)
    static func == (a: LiveInputs, b: LiveInputs) -> Bool {
        a.lightsUsed == b.lightsUsed && a.elev == b.elev && a.linked == b.linked && a.leader == b.leader && a.applying == b.applying && a.pos == b.pos && a.lights == b.lights && a.light == b.light && a.levels == b.levels
            && a.offsets.mapValues { "\($0.value) \($0.weight)" } == b.offsets.mapValues { "\($0.value) \($0.weight)" }
    }
}

struct ChartMonitor: Identifiable, Equatable {
    let id: String              // display uuid
    let label: String
    let day, blindDown, night: Double
    var nightLights: Double? = nil   // the level after sunset with the room lights on, when set
}

struct BrightnessChart: View {
    let latitude: Double, longitude: Double
    let now: Date
    let timeZone: TimeZone
    let monitors: [ChartMonitor]
    let hasBlind: Bool
    let tuning: Tuning          // with the elevations being edited
    let live: LiveInputs?
    let set: (String, Double) -> Void   // tuning field, elevation
    var showDegrees: String? = nil      // the docs animation: label this handle as if it were being dragged
    @State private var picked: String? = nil
    @State private var dragging: String? = nil

    static let dayColor = Color.orange, nightColor = Color.indigo
    let chartHeight: CGFloat = 190

    var mon: ChartMonitor? { monitors.first { $0.id == picked } ?? monitors.first }
    var day: (start: Date, length: TimeInterval) { dayBounds(now, timeZone: timeZone) }
    var samples: [(t: Double, e: Double)] {
        let d = day, key = "\(latitude) \(longitude) \(d.start.timeIntervalSince1970) \(d.length)"
        if let c = Self.cache, c.key == key { return c.samples }
        let s = daySamples(latitude: latitude, longitude: longitude, start: d.start, length: d.length)
        Self.cache = (key, s)
        return s
    }
    /// Today's sun changes once a day, not on every redraw or drag step.
    @MainActor static var cache: (key: String, samples: [(t: Double, e: Double)])?

    /// The monitor's levels in effect: Home Assistant's helpers where it has them.
    func levels(_ m: ChartMonitor) -> [Double] {
        effectiveLevels(local: [m.day, m.blindDown, m.night] + (m.nightLights.map { [$0] } ?? []), fromHA: live?.levels[m.id])
    }
    /// The line's level for an elevation: target()'s rule without its rounding, so the slopes draw smooth.
    func level(_ m: ChartMonitor, elev: Double, pos: Double) -> Double {
        let l = levels(m)
        let daytime = l[1] + (l[0] - l[1]) * pos / 100
        return l[2] + (daytime - l[2]) * daylightFraction(elevation: elev, tuning: tuning)
    }
    func clock(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = timeZone
        return f.string(from: day.start.addingTimeInterval((t * day.length / 60).rounded() * 60))
    }
    func fraction(hour: Int) -> Double {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        guard let d = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day.start) else { return Double(hour) / 24 }
        return d.timeIntervalSince(day.start) / day.length
    }

    var body: some View {
        if let m = mon {
            let s = samples
            VStack(alignment: .leading, spacing: 10) {
                if monitors.count > 1 {
                    Picker("Monitor", selection: Binding(get: { m.id }, set: { picked = $0 })) {
                        ForEach(monitors) { Text($0.label).tag($0.id) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                chart(m, s)
                legend(m)
                decides(m, s)
            }
        }
    }

    // MARK: chart

    func chart(_ m: ChartMonitor, _ s: [(t: Double, e: Double)]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing) { Text("100%"); Spacer(); Text("50%"); Spacer(); Text("0%") }
                .font(.caption2).foregroundStyle(.secondary).frame(height: chartHeight)
            VStack(spacing: 4) {
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    let x = { (t: Double) -> CGFloat in CGFloat(t) * w }
                    let y = { (v: Double) -> CGFloat in h - CGFloat(v / 100) * h }
                    let l = levels(m)
                    let open = s.map { (t: $0.t, v: level(m, elev: $0.e, pos: 100)) }
                    let closed = s.map { (t: $0.t, v: level(m, elev: $0.e, pos: 0)) }
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Self.nightColor.opacity(0.06))
                        // full daytime brightness today, shaded
                        ForEach(Array(sunSpans(s, line: tuning.sunDay).enumerated()), id: \.offset) { _, sp in
                            Rectangle().fill(Self.dayColor.opacity(0.09)).frame(width: max(0, x(sp.to) - x(sp.from)), height: h).offset(x: x(sp.from))
                        }
                        ForEach([25.0, 50, 75], id: \.self) { v in
                            Path { p in p.move(to: CGPoint(x: 0, y: y(v))); p.addLine(to: CGPoint(x: w, y: y(v))) }
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                        }
                        // the night level: the floor both lines share
                        Path { p in p.move(to: CGPoint(x: 0, y: y(l[2]))); p.addLine(to: CGPoint(x: w, y: y(l[2]))) }
                            .stroke(Self.nightColor.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        if hasBlind { line(closed, x: x, y: y).stroke(Self.dayColor.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [5, 4])) }
                        line(open, x: x, y: y).stroke(Self.dayColor, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                        nowDot(m, s, x: x, y: y)
                        handles(m, s, w: w, h: h, x: x, y: y, open: open)
                    }
                }
                .coordinateSpace(name: "brightnessChart")
                .frame(height: chartHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1)))
                GeometryReader { geo in
                    ForEach([0, 6, 12, 18], id: \.self) { hr in
                        Text(String(format: "%02d:00", hr)).font(.caption2).foregroundStyle(.secondary)
                            .position(x: max(16, fraction(hour: hr) * geo.size.width), y: 6)
                    }
                }.frame(height: 12)
            }
        }
    }

    func line(_ pts: [(t: Double, v: Double)], x: (Double) -> CGFloat, y: (Double) -> CGFloat) -> Path {
        Path { p in
            for (i, pt) in pts.enumerated() {
                let c = CGPoint(x: x(pt.t), y: y(pt.v))
                if i == 0 { p.move(to: c) } else { p.addLine(to: c) }
            }
        }
    }

    /// Where the monitor is right now: the level the rules give with today's blind, clouds and lights
    /// and any hand-set distance. Without a reading from the last tick it is a preview with the blind open.
    @ViewBuilder func nowDot(_ m: ChartMonitor, _ s: [(t: Double, e: Double)], x: (Double) -> CGFloat, y: (Double) -> CGFloat) -> some View {
        let t = now.timeIntervalSince(day.start) / day.length
        let d = decision(m)
        Circle().fill(Color.primary).frame(width: 10, height: 10).overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            .position(x: x(t), y: y(Double(d.level))).allowsHitTesting(false)
        Text("\(dotTitle) \(d.level)%").font(.caption2.weight(.semibold))
            .padding(.horizontal, 4).background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
            .position(x: min(max(x(t), 34), x(1) - 34), y: max(y(Double(d.level)) - 13, 9)).allowsHitTesting(false)
    }

    func decision(_ m: ChartMonitor) -> Decision {
        let l = levels(m)
        let elev = live?.elev ?? solarElevation(latitude: latitude, longitude: longitude, at: now)
        let o = live?.offsets[m.id]
        return explain(day: l[0], blindDown: l[1], night: l[2], elev: elev, pos: hasBlind ? (live?.pos ?? 100) : nil,
                       lights: live?.lightsUsed[m.id] ?? live?.lights ?? false, tuning: tuning, light: live?.light ?? 1, offset: o?.value,
                       offsetWeight: o?.weight ?? 1, linked: live?.linked[m.id], leader: live?.leader ?? "", applying: live?.applying ?? true,
                       nightLights: nightLightsLevel(l))
    }
    /// "Now 77%" while Daylit sets it; "Target 77%" when Automatic is off or this Mac is idle.
    var dotTitle: String { live?.applying == false ? "Target" : "Now" }

    // MARK: handles

    struct HandleSpec { let id: String; let isDay: Bool; let color: Color }
    var specs: [HandleSpec] { [HandleSpec(id: "brightness.sunDay", isDay: true, color: Self.dayColor),
                               HandleSpec(id: "brightness.sunNight", isDay: false, color: Self.nightColor)] }

    func handles(_ m: ChartMonitor, _ s: [(t: Double, e: Double)], w: CGFloat, h: CGFloat,
                 x: @escaping (Double) -> CGFloat, y: @escaping (Double) -> CGFloat, open: [(t: Double, v: Double)]) -> some View {
        let l = levels(m)
        let places = specs.map { handlePlace(s, line: $0.isDay ? tuning.sunDay : tuning.sunNight) }
        let rowY = specs.map { $0.isDay ? Double(y(l[0])) : Double(y(l[2])) }
        // Labels sit under their handle, moved apart so they never overlap.
        let labelY = spreadLabels(rowY.map { $0 + 24 }, gap: 22, height: Double(h))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(specs.enumerated()), id: \.offset) { i, sp in
                let p = places[i]
                let ends = [p.at] + (p.partner.map { [$0] } ?? [])
                ForEach(Array(ends.enumerated()), id: \.offset) { _, t in
                    grip(sp, place: p, s, w: w).position(x: x(t), y: y(sp.isDay ? l[0] : l[2]))
                }
                let labelX = min(max(x(p.at), 110), w - 110)
                Text(title(sp, p, s)).font(.caption.weight(.medium)).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.15), radius: 1))
                    .fixedSize()
                    .position(x: labelX, y: CGFloat(labelY[i]))
                    .allowsHitTesting(false)
            }
        }
    }

    func grip(_ sp: HandleSpec, place p: HandlePlace, _ s: [(t: Double, e: Double)], w: CGFloat) -> some View {
        let other = sp.isDay ? tuning.sunNight : tuning.sunDay
        let value = sp.isDay ? tuning.sunDay : tuning.sunNight
        return Capsule().fill(sp.color.opacity(p.parked ? 0.55 : 1)).frame(width: 12, height: 26)
            .overlay(VStack(spacing: 2.5) { ForEach(0..<3, id: \.self) { _ in Rectangle().fill(.white).frame(width: 6, height: 1.2) } })
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .contentShape(Rectangle().inset(by: -8))
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("brightnessChart"))
                .onChanged { g in
                    dragging = sp.id
                    let t = min(max(Double(g.location.x / w), 0), 1)
                    if let v = draggedElevation(s, to: t, day: sp.isDay, other: other, parkedAt: p.parked ? p.at : nil) { set(sp.id, v) }
                }
                .onEnded { _ in dragging = nil })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sp.isDay ? "Full brightness" : "Night level")
            .accessibilityValue("\(SettingsView.fmt(value)) degrees, \(title(sp, p, s))")
            .accessibilityAdjustableAction { dir in
                // Later in the morning = a higher sun for the full-day line, a lower one for night.
                let step = (dir == .increment ? 0.5 : -0.5)
                let v = value + step
                set(sp.id, sp.isDay ? max(v, other + 0.5) : min(v, other - 0.5))
            }
    }

    func title(_ sp: HandleSpec, _ p: HandlePlace, _ s: [(t: Double, e: Double)]) -> String {
        let value = sp.isDay ? tuning.sunDay : tuning.sunNight
        let degrees = (dragging ?? showDegrees) == sp.id ? " · sun \(SettingsView.fmt(value))° up" : ""
        if p.parked {
            let v = SettingsView.fmt(value)
            switch (sp.isDay, p.sunAbove) {
            case (true, false): return "No full brightness today: the sun stays under \(v)°"
            case (true, true): return "Full brightness all day: the sun stays above \(v)°"
            case (false, false): return "Night level all day: the sun stays under \(v)°"
            case (false, true): return "No night level today: the sun stays above \(v)°"
            }
        }
        if sp.isDay {
            return "Full brightness today " + sunSpanLabel(sunSpans(s, line: value), clock: clock) + degrees
        }
        return "Night level today: " + sunSpanLabel(sunSpans(s, line: value, below: true), clock: clock) + degrees
    }

    // MARK: legend and decision

    func legend(_ m: ChartMonitor) -> some View {
        let l = levels(m)
        return HStack(spacing: 14) {
            key(Rectangle().fill(Self.dayColor).frame(width: 16, height: 2.5), hasBlind ? "Blind open · day \(Int(l[0]))%" : "Day \(Int(l[0]))%")
            if hasBlind { key(Rectangle().fill(Self.dayColor.opacity(0.8)).frame(width: 16, height: 2), "Blind closed · \(Int(l[1]))%") }
            key(Rectangle().fill(Self.nightColor.opacity(0.45)).frame(width: 16, height: 2), "Night · \(Int(l[2]))%")
        }
        .font(.caption).foregroundStyle(.secondary).padding(.leading, 34)
    }
    func key(_ swatch: some View, _ text: String) -> some View { HStack(spacing: 5) { swatch; Text(text) } }

    func decides(_ m: ChartMonitor, _ s: [(t: Double, e: Double)]) -> some View {
        let d = decision(m)
        return VStack(alignment: .leading, spacing: 6) {
            Text(live == nil ? "How Daylit decides (preview, blind open)" : "How Daylit decides, right now").font(.caption.weight(.semibold))
            HStack(spacing: 5) {
                ForEach(Array(d.steps.enumerated()), id: \.offset) { i, st in
                    if i > 0 { Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(st.title).font(.caption2).foregroundStyle(.secondary)
                        Text(st.value).font(.caption.weight(st.final ? .bold : .medium)).monospacedDigit()
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                    .fixedSize()
                }
            }
            if live?.applying == false {
                Text("Automatic is off or this Mac is idle: the screen stays where it is until it takes over again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Each handle is one sun height, so its morning and evening times move together and shift through the year. A level you set by hand keeps its distance until dusk.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }
}
