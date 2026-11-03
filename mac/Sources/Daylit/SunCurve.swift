// Today's sun as a picture: its height through the day at the user's location, with draggable
// lines for the elevations the rules use. Each line shows when the sun crosses it today, so nobody
// has to think in degrees. Below, how bright a monitor would be hour by hour.
import SwiftUI
import AppKit
import DaylitCore

struct SunMarker: Identifiable {
    let id: String          // the tuning field ("brightness.sunDay")
    let title: String       // "Full day"
    let color: Color
    var value: Double       // elevation, °
    var below = false       // the state applies below the line (night, dark): label its times the other way round
}

struct SunCurve: View {
    let latitude: Double, longitude: Double
    let now: Date
    let timeZone: TimeZone
    var markers: [SunMarker]
    let set: (String, Double) -> Void
    /// Optional brightness preview: the level (0–100) for an elevation.
    var level: ((Double) -> Int)? = nil
    var levelTitle = ""

    // Today's elevations every 10 minutes, local midnight to midnight.
    var samples: [(t: Double, e: Double)] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let start = cal.startOfDay(for: now)
        return (0...144).map { i in
            let d = start.addingTimeInterval(Double(i) * 600)
            return (Double(i) / 144, solarElevation(latitude: latitude, longitude: longitude, at: d))
        }
    }

    var body: some View {
        let s = samples
        // The chart shows the whole day plus room for every line, so a handle never leaves it.
        let marks = markers.map(\.value)
        let top = max(15, (s.map(\.e).max() ?? 15) + 5, (marks.max() ?? 0) + 4)
        let bottom = min(-12, s.map(\.e).min() ?? -12, (marks.min() ?? 0) - 4)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let y = { (e: Double) -> CGFloat in CGFloat((top - e) / (top - bottom)) * h }
                ZStack(alignment: .topLeading) {
                    // night below the horizon, day above
                    Rectangle().fill(Color.indigo.opacity(0.12)).frame(height: h - y(0)).offset(y: y(0))
                    Rectangle().fill(Color.orange.opacity(0.06)).frame(height: y(0))
                    Path { p in p.move(to: CGPoint(x: 0, y: y(0))); p.addLine(to: CGPoint(x: w, y: y(0))) }
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    Path { p in
                        for (i, pt) in s.enumerated() {
                            let c = CGPoint(x: pt.t * w, y: y(pt.e))
                            if i == 0 { p.move(to: c) } else { p.addLine(to: c) }
                        }
                    }
                    .stroke(LinearGradient(colors: [.orange, .yellow, .orange], startPoint: .leading, endPoint: .trailing), lineWidth: 2.5)
                    // the sun now
                    let nowE = solarElevation(latitude: latitude, longitude: longitude, at: now)
                    Circle().fill(Color.yellow).overlay(Circle().stroke(Color.orange, lineWidth: 1.5))
                        .frame(width: 12, height: 12).position(x: fraction(of: now) * w, y: y(nowE)).allowsHitTesting(false)
                    ForEach(markers) { m in
                        markerLine(m, w: w, y: y(m.value), h: h, top: top, bottom: bottom)
                    }
                    ForEach([6, 12, 18], id: \.self) { hr in
                        Text(String(format: "%02d:00", hr)).font(.caption2).foregroundStyle(.secondary)
                            .position(x: Double(hr) / 24 * w, y: h - 7).allowsHitTesting(false)
                    }
                }
            }
            .coordinateSpace(name: "sunCurve")
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1)))

            if let level {
                Text(levelTitle).font(.caption).foregroundStyle(.secondary)
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        for pt in s { p.addLine(to: CGPoint(x: pt.t * w, y: h - CGFloat(level(pt.e)) / 100 * h)) }
                        p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
                    }
                    .fill(Color.accentColor.opacity(0.35))
                }
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.1)))
            }
        }
    }

    func markerLine(_ m: SunMarker, w: CGFloat, y: CGFloat, h: CGFloat, top: Double, bottom: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                .stroke(m.color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .allowsHitTesting(false)
            // The handle: drag it up or down (half-degree steps).
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(Circle().fill(m.color))
                Text("\(m.title) · \(crossings(m.value, below: m.below))").font(.caption.weight(.medium))
            }
            .padding(.leading, 2).padding(.trailing, 8).padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule().stroke(m.color.opacity(0.6)))
            .fixedSize()
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("sunCurve")).onChanged { g in
                let e = top - Double(g.location.y / h) * (top - bottom)
                set(m.id, (min(max(e, -18), 60) * 2).rounded() / 2)   // the range tuning accepts
            })
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .position(x: 120, y: min(max(y, 12), h - 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(m.title)
            .accessibilityValue("\(SettingsView.fmt(m.value)) degrees, \(crossings(m.value, below: m.below))")
            .accessibilityAdjustableAction { dir in set(m.id, m.value + (dir == .increment ? 0.5 : -0.5)) }
        }
    }

    func fraction(of d: Date) -> Double {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        return d.timeIntervalSince(cal.startOfDay(for: d)) / 86400
    }

    /// Today's times for this elevation: "06:52 – 21:14" while the sun is above it, or for a state that
    /// applies below it, "until 06:52 · from 21:14".
    func crossings(_ e: Double, below: Bool = false) -> String {
        let s = samples
        func time(_ i: Int) -> String {
            let a = s[i - 1], b = s[i]
            let t = a.t + (b.t - a.t) * (e - a.e) / (b.e - a.e)
            let mins = Int((t * 1440).rounded())
            return String(format: "%02d:%02d", (mins / 60) % 24, mins % 60)
        }
        let up = (1..<s.count).first { s[$0 - 1].e < e && s[$0].e >= e }
        let down = (1..<s.count).last { s[$0 - 1].e >= e && s[$0].e < e }
        let allAbove = (s.first?.e ?? 0) >= e
        if below {
            switch (up, down) {
            case let (u?, d?): return "until \(time(u)) · from \(time(d))"
            case (nil, nil): return allAbove ? "not today" : "all day"
            case let (u?, nil): return "until \(time(u))"
            case let (nil, d?): return "from \(time(d))"
            }
        }
        switch (up, down) {
        case let (u?, d?): return "\(time(u)) – \(time(d))"
        case (nil, nil): return allAbove ? "all day" : "not today"
        case let (u?, nil): return "from \(time(u))"
        case let (nil, d?): return "until \(time(d))"
        }
    }
}
