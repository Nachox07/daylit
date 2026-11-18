// The shared cases in tests/parity/: the Windows tests run the same files (windows/tests/ParityTests.cs),
// so the two apps cannot drift apart on these rules. CONTRIBUTING.md → Shared test cases says how to add one.
import XCTest
@testable import DaylitCore

final class ParityTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../tests/parity").standardizedFileURL

    /// Each file in tests/parity and the function that runs one of its cases (`fn`, `in`) → the result as JSON values.
    static let runners: [String: (String, [String: Any]) throws -> Any] = [
        "update.json": update, "ha-numbers.json": haNumbers, "levels.json": levels, "hold.json": hold,
        "config-load.json": config, "config-edit.json": configEdit, "suggest.json": suggest, "ha-cache.json": haCache, "read-state.json": readState,
    ]

    /// Every file in tests/parity runs: one with no runner fails, so a new area cannot be skipped by accident.
    func testEverySharedCase() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.dir.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(files.isEmpty, "no cases found in \(Self.dir.path)")
        for f in files {
            guard Self.runners[f] != nil else { XCTFail("tests/parity/\(f) has no runner in ParityTests.swift"); continue }
            try run(f)
        }
    }

    func run(_ file: String) throws {
        let d = try Data(contentsOf: Self.dir.appendingPathComponent(file))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]], "\(file) has no cases")
        guard let runner = Self.runners[file] else { return }
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as? String ?? "?", fn = c["fn"] as? String ?? "?"
            let input = c["in"] as? [String: Any] ?? [:]
            do {
                let got = try runner(fn, input)
                if !Self.same(c["out"] ?? NSNull(), got) {
                    XCTFail("\(file): \(name): expected \(Self.show(c["out"] ?? NSNull())), got \(Self.show(got))")
                }
            } catch {
                XCTFail("\(file): \(name): \(error)")
            }
        }
    }

    struct UnknownFunction: Error, CustomStringConvertible { let fn: String; var description: String { "no runner for fn \"\(fn)\"" } }

    // MARK: the areas

    static func update(_ fn: String, _ i: [String: Any]) throws -> Any {
        switch fn {
        case "isNewer": return UpdateCheck.isNewer(str(i["a"]), than: str(i["b"]))
        case "parse": return UpdateCheck.parse(str(i["s"])).map { $0 as Any } ?? NSNull()
        case "isDevBuild": return UpdateCheck.isDevBuild(optStr(i["v"]))
        case "versionLine": return UpdateCheck.versionLine(optStr(i["v"]))
        case "releasePage": return UpdateCheck.releasePage(optStr(i["v"])) ?? NSNull()
        case "due": return UpdateCheck.due(elapsed: optNum(i["elapsed"]))
        default: throw UnknownFunction(fn: fn)
        }
    }

    static func haNumbers(_ fn: String, _ i: [String: Any]) throws -> Any {
        switch fn {
        case "bound":
            let v = num(i["v"])
            switch str(i["kind"]) {
            case "elevation": return HABounds.elevation(v)
            case "position": return HABounds.position(v)
            case "brightness": return HABounds.brightness(v)
            case "saturation": return HABounds.saturation(v)
            case "reading": return HABounds.reading(v)
            case "age": return HABounds.age(v)
            case let k: throw UnknownFunction(fn: "bound " + k)
            }
        case "row": return HABounds.row(nums(i["r"]))
        case "lightsNote": return lightsNote(lights: bool(i["lights"]), bri: num(i["bri"]), sat: num(i["sat"]))
        default: throw UnknownFunction(fn: fn)
        }
    }

    static func levels(_ fn: String, _ i: [String: Any]) throws -> Any {
        func nullable<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
        switch fn {
        case "target":
            let l = nums(i["levels"])
            return target(day: l[0], blindDown: l[1], night: l[2], elev: num(i["elev"]), pos: num(i["pos"]), lights: bool(i["lights"]),
                          light: optNum(i["light"]) ?? 1, nightLights: l.count > 3 && l[3] >= 0 ? l[3] : nil)
        case "blindPosition": return blindPosition(reported: num(i["reported"]), last: optNum(i["last"]))
        case "clampLevel": return clampLevel(num(i["v"]))
        case "automaticNow":
            return automaticNow(hasSwitch: bool(i["hasSwitch"]), fromHA: optBool(i["fromHA"]), lastFromHA: optBool(i["lastFromHA"]), local: bool(i["local"]))
        case "automaticFallback": return automaticFallback(hasSwitch: bool(i["hasSwitch"]), lastFromHA: optBool(i["lastFromHA"]), local: bool(i["local"]))
        case "storedAutomatic":
            return nullable(storedAutomatic(value: optBool(i["value"]), entity: optStr(i["entity"]), configured: optStr(i["configured"])))
        case "roomLights":
            return roomLights(reported: bool(i["reported"]), fromHA: bool(i["fromHA"]), last: optBool(i["last"]), hasNightLights: bool(i["hasNightLights"]))
        case "offsetWeight": return nullable(offsetWeight(sun: num(i["sun"]), setAt: num(i["setAt"]), age: optNum(i["age"])))
        case "userLevelWins": return userLevelWins(atRead: optInt(i["atRead"]), now: optInt(i["now"]), held: bool(i["held"]))
        case "levelToDecideOn": return levelToDecideOn(read: int(i["read"]), atRead: optInt(i["atRead"]), model: optInt(i["model"]), held: bool(i["held"]))
        case "levelAfterWrite":
            return nullable(levelAfterWrite(new: optInt(i["new"]), ok: bool(i["ok"]), atStart: optInt(i["atStart"]), now: optInt(i["now"]), held: bool(i["held"])))
        default: throw UnknownFunction(fn: fn)
        }
    }

    static func hold(_ fn: String, _ i: [String: Any]) throws -> Any {
        guard fn == "decide" else { throw UnknownFunction(fn: fn) }
        let s = i["state"] as? [String: Any] ?? [:]
        let state = HoldState(lastSet: optInt(s["lastSet"]), lastTarget: optInt(s["lastTarget"]), remoteSeen: optNum(s["remoteSeen"]),
                              offset: optInt(s["offset"]), offsetSun: optNum(s["offsetSun"]), offsetAt: optNum(s["offsetAt"]),
                              remoteValue: optNum(s["remoteValue"]))
        let remote = (i["remote"] as? [String: Any]).map { RemoteSet(value: num($0["value"]), changed: num($0["changed"])) }
        let step = decide(current: int(i["current"]), want: int(i["want"]), remote: remote, state: state, here: bool(i["here"]),
                          auto: bool(i["auto"]), dragging: bool(i["dragging"]), sun: num(i["sun"]), touched: bool(i["touched"]),
                          now: num(i["now"]), dayOf: { Int(($0 / 86400).rounded(.down)) })
        func n<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
        let st = step.state
        return ["write": n(step.write), "remote": n(step.remote), "applied": step.applied, "manual": step.manual,
                "state": ["lastSet": n(st.lastSet), "lastTarget": n(st.lastTarget), "remoteSeen": n(st.remoteSeen), "remoteValue": n(st.remoteValue),
                          "offset": n(st.offset), "offsetSun": n(st.offsetSun), "offsetAt": n(st.offsetAt)]] as [String: Any]
    }

    static func config(_ fn: String, _ i: [String: Any]) throws -> Any {
        guard fn == "parse" else { throw UnknownFunction(fn: fn) }
        let (c, err) = Config.parse(Data(str(i["text"]).utf8))
        let (source, sourceProblem) = (c ?? Config()).resolvedSource()
        let problem = c == nil ? "json" : err != nil ? "value" : sourceProblem != nil ? "source" : "none"
        let name: String
        switch source { case .off: name = "off"; case .sun: name = "sun"; case .homeAssistant: name = "homeAssistant" }
        return ["problem": problem, "source": name]
    }

    static func configEdit(_ fn: String, _ i: [String: Any]) throws -> Any {
        let original = optStr(i["original"]).map { Data($0.utf8) }
        func saved(_ make: () throws -> Data) -> Any {
            guard let d = try? make() else { return ["error": true] }
            return (try? JSONSerialization.jsonObject(with: d)) ?? ["error": true]
        }
        switch fn {
        case "setLevels":
            let levels = (i["levels"] as? [String: Any] ?? [:]).mapValues { int($0) }
            return saved { try ConfigPatch.setLevels(levels, display: str(i["display"]), suggestedMatch: str(i["suggestedMatch"]), in: original) }
        case "apply":
            let e = i["edit"] as? [String: Any] ?? [:]
            let monitors = (e["monitors"] as? [[String: Any]] ?? []).map {
                SettingsEdit.Monitor(name: str($0["name"]), suggestedMatch: str($0["suggestedMatch"]), label: str($0["label"]),
                                     day: int($0["day"]), blindDown: int($0["blindDown"]), night: int($0["night"]))
            }
            let edit = SettingsEdit(source: str(e["source"]), latitude: optNum(e["latitude"]), longitude: optNum(e["longitude"]), monitors: monitors,
                                    haURL: optStr(e["haURL"]) ?? "", autoSwitch: optStr(e["autoSwitch"]) ?? "", sun: optStr(e["sun"]) ?? "",
                                    cover: optStr(e["cover"]) ?? "", lights: optStr(e["lights"]) ?? "")
            return saved { try ConfigPatch.apply(edit, to: original) }
        case "hasComments": return ConfigText.hasComments(Data(str(i["text"]).utf8))
        default: throw UnknownFunction(fn: fn)
        }
    }

    static func suggest(_ fn: String, _ i: [String: Any]) throws -> Any {
        switch fn {
        case "applyClearsOffset": return Suggest.applyClearsOffset(mainInHA: optBool(i["mainInHA"]), fileWritten: bool(i["fileWritten"]))
        case "roundToStep":
            let s = i["step"] as? [String: Any] ?? [:]
            return Suggest.roundToStep(num(i["v"]), NumberStep(min: num(s["min"]), max: num(s["max"]), step: num(s["step"]))).map { $0 as Any } ?? NSNull()
        case "fmt": return Suggestion.fmt(num(i["v"]))
        case "sameLevels": return Suggest.sameLevels(nums(i["a"]), nums(i["b"]))
        case "numberStep":
            guard let st = NumberStep.parse(Data(str(i["json"]).utf8)) else { return NSNull() }
            return ["min": st.min, "max": st.max, "step": st.step]
        case "settleHolds":
            let c = i["context"] as? [String: Any] ?? [:]
            let ctx = SampleContext(follower: bool(c["follower"]), writeFailed: bool(c["writeFailed"]), idle: bool(c["idle"]),
                                    paused: bool(c["paused"]), sunFallback: bool(c["sunFallback"]))
            return Suggest.settleHolds(auto: bool(i["auto"]), offsetHeld: bool(i["offsetHeld"]), context: ctx)
        case "nextChange":
            let samples = nums(i["at"]).map { Sample(monitor: "m", chosen: 50, auto: 60, s: 1, p: 1, elev: 20, lights: false, levels: [70, 40, 20], at: $0) }
            return Suggest.nextChange(samples: samples, dismissedUntil: nums(i["dismissedUntil"]), now: num(i["now"])).map { $0 as Any } ?? NSNull()
        case "due": return Suggest.due(optNum(i["next"]), now: num(i["now"]))
        default: throw UnknownFunction(fn: fn)
        }
    }

    static func haCache(_ fn: String, _ i: [String: Any]) throws -> Any {
        switch fn {
        case "stale": return HACacheRule.stale(oldURL: optStr(i["oldURL"]), newURL: optStr(i["newURL"]),
                                               oldEntity: optStr(i["oldEntity"]), newEntity: optStr(i["newEntity"]))
        case "levelsKey": return HACacheRule.levelsKey(day: optStr(i["day"]), blindDown: optStr(i["blindDown"]), night: optStr(i["night"]),
                                                       nightLights: optStr(i["nightLights"])).map { $0 as Any } ?? NSNull()
        default: throw UnknownFunction(fn: fn)
        }
    }

    static func readState(_ fn: String, _ i: [String: Any]) throws -> Any {
        let states: [String: ReadState] = ["unknown": .unknown, "readable": .readable, "writeOnly": .writeOnly, "silent": .silent]
        func name(_ r: ReadState) -> String { states.first { $0.value == r }!.key }
        let st = states[str(i["state"])] ?? .unknown
        switch fn {
        case "afterRead": return name(st.afterRead(ok: bool(i["ok"])))
        case "afterUserWrite": return name(st.afterUserWrite(ok: bool(i["ok"])))
        case "current": return st.current(reading: optInt(i["reading"]), slider: int(i["slider"])).map { $0 as Any } ?? NSNull()
        case "usable": return st.usable
        case "appliedAfter": return ReadState.appliedAfter(ok: bool(i["ok"]), sent: int(i["sent"]), applied: optInt(i["applied"])).map { $0 as Any } ?? NSNull()
        case "revertAfterUserWrite": return st.revertAfterUserWrite(ok: bool(i["ok"]), applied: optInt(i["applied"])).map { $0 as Any } ?? NSNull()
        default: throw UnknownFunction(fn: fn)
        }
    }

    // MARK: JSON values

    static func isBool(_ v: Any?) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    static func isNull(_ v: Any?) -> Bool { v == nil || v is NSNull }
    /// A number, or one of the texts "NaN", "Infinity", "-Infinity" (JSON has no such numbers).
    static func num(_ v: Any?) -> Double {
        if let s = v as? String { return s == "NaN" ? .nan : s == "Infinity" ? .infinity : s == "-Infinity" ? -.infinity : Double(s) ?? .nan }
        return (v as? NSNumber)?.doubleValue ?? .nan
    }
    static func optNum(_ v: Any?) -> Double? { isNull(v) ? nil : num(v) }
    static func nums(_ v: Any?) -> [Double] { (v as? [Any] ?? []).map { num($0) } }
    static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
    static func optInt(_ v: Any?) -> Int? { isNull(v) ? nil : int(v) }
    static func bool(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? false }
    static func optBool(_ v: Any?) -> Bool? { isNull(v) ? nil : bool(v) }
    static func str(_ v: Any?) -> String { v as? String ?? "" }
    static func optStr(_ v: Any?) -> String? { v as? String }

    /// The expected JSON value and the result agree: numbers to 1e-9 (relative), lists and objects member by member.
    static func same(_ want: Any?, _ got: Any?) -> Bool {
        if isNull(want) || isNull(got) { return isNull(want) && isNull(got) }
        if isBool(want) || isBool(got) { return isBool(want) && isBool(got) && bool(want) == bool(got) }
        if let w = want as? NSNumber {
            guard let g = got as? NSNumber else { return false }
            let a = w.doubleValue, b = g.doubleValue
            return a == b || abs(a - b) <= 1e-9 * max(1, abs(a))
        }
        if let w = want as? String { return (got as? String) == w }
        if let w = want as? [Any] {
            guard let g = got as? [Any], g.count == w.count else { return false }
            return zip(w, g).allSatisfy { same($0, $1) }
        }
        if let w = want as? [String: Any] {
            guard let g = got as? [String: Any], Set(g.keys) == Set(w.keys) else { return false }
            return w.allSatisfy { same($0.value, g[$0.key]) }
        }
        return false
    }

    static func show(_ v: Any) -> String {
        if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys]), let s = String(data: d, encoding: .utf8) { return s }
        return "\(v)"
    }
}
