import Foundation

/// Solar elevation in degrees (same formula as the Windows app; within 0.01° of Home Assistant's sun.sun).
public func solarElevation(latitude: Double, longitude: Double, at date: Date = Date()) -> Double {
    func rad(_ x: Double) -> Double { x * .pi / 180 }
    func deg(_ x: Double) -> Double { x * 180 / .pi }
    func mod(_ a: Double, _ n: Double) -> Double { let r = a.truncatingRemainder(dividingBy: n); return r < 0 ? r + n : r }
    let d = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
    let g = rad(mod(357.529 + 0.98560028 * d, 360))
    let q = mod(280.459 + 0.98564736 * d, 360)
    let L = rad(q + 1.915 * sin(g) + 0.020 * sin(2 * g))
    let e = rad(23.439 - 0.00000036 * d)
    let ra = deg(atan2(cos(e) * sin(L), cos(L)))
    let dec = asin(sin(e) * sin(L))
    let gmst = mod(18.697374558 + 24.06570982441908 * d, 24)
    let ha = rad(gmst * 15 + longitude - ra)
    return deg(asin(sin(rad(latitude)) * sin(dec) + cos(rad(latitude)) * cos(dec) * cos(ha)))
}

/// How much daylight counts, 0...1: 0 below -3° elevation, 1 from 12°.
public func daylightFraction(elevation: Double) -> Double { min(max((elevation + 3) / 15, 0), 1) }
