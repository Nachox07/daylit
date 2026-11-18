// The shared cases in tests/parity/: the macOS tests run the same files (mac/Tests/DaylitCoreTests/ParityTests.swift),
// so the two apps cannot drift apart on these rules. CONTRIBUTING.md → Shared test cases says how to add one.
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace Daylit.Tests;

public class ParityTests {
    static readonly string Dir = Path.Combine(AppContext.BaseDirectory, "parity");

    /// Each file in tests/parity and the function that runs one of its cases (`fn`, `in`) → the result as JSON.
    static readonly Dictionary<string, Func<string, JsonObject, JsonNode?>> Runners = new() {
        ["update.json"] = Update, ["ha-numbers.json"] = HaNumbers, ["levels.json"] = Levels, ["hold.json"] = HoldCases,
        ["config-load.json"] = ConfigCases, ["config-edit.json"] = ConfigEdit, ["suggest.json"] = SuggestCases,
    };

    /// Every file in tests/parity runs: one with no runner fails, so a new area cannot be skipped by accident.
    [Fact]
    public void EverySharedCase() {
        var files = Directory.GetFiles(Dir, "*.json").Select(f => Path.GetFileName(f)!).Order().ToList();
        Assert.NotEmpty(files);
        var failures = new List<string>();
        foreach (var f in files) {
            if (!Runners.ContainsKey(f)) failures.Add($"tests/parity/{f} has no runner in ParityTests.cs");
            else failures.AddRange(Run(f));
        }
        Assert.True(failures.Count == 0, string.Join("\n", failures));
    }

    static List<string> Run(string file) {
        var root = JsonNode.Parse(File.ReadAllText(Path.Combine(Dir, file)))!.AsObject();
        var cases = root["cases"]!.AsArray();
        Assert.NotEmpty(cases);
        var failures = new List<string>();
        foreach (var c in cases.Select(x => x!.AsObject())) {
            string name = (string?)c["name"] ?? "?", fn = (string?)c["fn"] ?? "?";
            try {
                var got = Runners[file](fn, c["in"]?.AsObject() ?? new JsonObject());
                if (!Same(c["out"], got)) failures.Add($"{file}: {name}: expected {Show(c["out"])}, got {Show(got)}");
            } catch (Exception e) {
                failures.Add($"{file}: {name}: {e.GetType().Name}: {e.Message}");
            }
        }
        return failures;
    }

    sealed class UnknownFunction(string fn) : Exception($"no runner for fn \"{fn}\"");

    // MARK: the areas

    static JsonNode? Update(string fn, JsonObject i) => fn switch {
        "isNewer" => UpdateCheck.IsNewer(Str(i["a"]), Str(i["b"])),
        "parse" => UpdateCheck.Parse(Str(i["s"])) is { } p ? new JsonArray(p.Select(n => (JsonNode)n).ToArray()) : null,
        "isDevBuild" => UpdateCheck.IsDevBuild(OptStr(i["v"])),
        "due" => UpdateCheck.Due(OptNum(i["elapsed"])),
        _ => throw new UnknownFunction(fn),
    };

    static JsonNode? HaNumbers(string fn, JsonObject i) {
        switch (fn) {
            case "bound":
                double v = Num(i["v"]);
                return Str(i["kind"]) switch {
                    "elevation" => HaBounds.Elevation(v), "position" => HaBounds.Position(v), "brightness" => HaBounds.Brightness(v),
                    "saturation" => HaBounds.Saturation(v), "reading" => HaBounds.Reading(v), "age" => HaBounds.Age(v),
                    var k => throw new UnknownFunction("bound " + k),
                };
            case "row": return Arr(HaBounds.Row(Nums(i["r"])));
            case "lightsNote": return Rules.LightsNote(Bool(i["lights"]), Num(i["bri"]), Num(i["sat"]));
            default: throw new UnknownFunction(fn);
        }
    }

    static JsonNode? Levels(string fn, JsonObject i) {
        var t = new Tuning();
        switch (fn) {
            case "target":
                double elev = Num(i["elev"]);
                return Rules.Target(Nums(i["levels"]), Num(i["pos"]), Bool(i["lights"]), t.Fraction(elev), t, elev < t.LightsBoostSunBelow,
                                    OptNum(i["light"]) ?? 1);
            case "blindPosition": return Rules.BlindPosition(Num(i["reported"]), OptNum(i["last"]));
            case "clampLevel": return Rules.ClampLevel(Num(i["v"]));
            case "automaticNow": return Rules.AutomaticNow(Bool(i["hasSwitch"]), OptBool(i["fromHA"]), OptBool(i["lastFromHA"]), Bool(i["local"]));
            case "automaticFallback": return Rules.AutomaticFallback(Bool(i["hasSwitch"]), OptBool(i["lastFromHA"]), Bool(i["local"]));
            case "storedAutomatic": return Rules.StoredAutomatic(OptBool(i["value"]), OptStr(i["entity"]), OptStr(i["configured"]));
            case "roomLights": return Rules.RoomLights(Bool(i["reported"]), Bool(i["fromHA"]), OptBool(i["last"]), Bool(i["hasNightLights"]));
            case "offsetWeight": return Rules.OffsetWeight(Num(i["sun"]), Num(i["setAt"]), OptNum(i["age"]));
            case "userLevelWins": return Rules.UserLevelWins(OptInt(i["atRead"]), OptInt(i["now"]), Bool(i["held"]));
            case "levelToDecideOn": return Rules.LevelToDecideOn(OptInt(i["read"]), OptInt(i["atRead"]), OptInt(i["model"]), Bool(i["held"]));
            case "levelAfterWrite": return Rules.LevelAfterWrite(OptInt(i["new"]), Bool(i["ok"]), OptInt(i["atStart"]), OptInt(i["now"]), Bool(i["held"]));
            default: throw new UnknownFunction(fn);
        }
    }

    static JsonNode? HoldCases(string fn, JsonObject i) {
        if (fn != "decide") throw new UnknownFunction(fn);
        var s = i["state"]?.AsObject() ?? new JsonObject();
        var hold = new Hold(OptNum(s["remoteSeen"]), OptInt(s["lastSet"]), OptInt(s["lastTarget"]), OptInt(s["offset"]), OptNum(s["offsetSun"]),
                            OptNum(s["offsetAt"]), OptNum(s["remoteValue"]));
        (double, double)? remote = i["remote"] is JsonObject r ? (Num(r["value"]), Num(r["changed"])) : null;
        var step = Rules.Decide(Int(i["current"]), Int(i["want"]), remote, hold, Bool(i["auto"]), Bool(i["here"]), Num(i["sun"]), Bool(i["touched"]),
                                Bool(i["dragging"]), Num(i["now"]), x => (int)Math.Floor(x / 86400));
        var st = step.State;
        return new JsonObject {
            ["write"] = step.Write, ["remote"] = step.Remote, ["applied"] = step.Applied, ["manual"] = step.Manual,
            ["state"] = new JsonObject {
                ["lastSet"] = st.LastSet, ["lastTarget"] = st.LastTarget, ["remoteSeen"] = st.RemoteSeen, ["remoteValue"] = st.RemoteValue,
                ["offset"] = st.Offset, ["offsetSun"] = st.OffsetSun, ["offsetAt"] = st.OffsetAt,
            },
        };
    }

    static JsonNode? ConfigCases(string fn, JsonObject i) {
        if (fn != "parse") throw new UnknownFunction(fn);
        var (cfg, _, problem) = Config.Parse(Str(i["text"]));
        return new JsonObject {
            ["problem"] = problem switch { Config.Problem.Json => "json", Config.Problem.Value => "value", Config.Problem.Source => "source", _ => "none" },
            ["source"] = cfg.Effective switch { Source.Sun => "sun", Source.HomeAssistant => "homeAssistant", _ => "off" },
        };
    }

    static JsonNode? ConfigEdit(string fn, JsonObject i) {
        string? original = OptStr(i["original"]);
        static JsonNode? Saved(Func<string> make) {
            try { return JsonNode.Parse(make()); }
            catch (Exception e) when (e is InvalidDataException or JsonException) { return new JsonObject { ["error"] = true }; }
        }
        switch (fn) {
            case "setLevels":
                var levels = (i["levels"]?.AsObject() ?? new JsonObject()).ToDictionary(p => p.Key, p => Int(p.Value));
                return Saved(() => ConfigPatch.SetLevels(levels, Str(i["display"]), Str(i["suggestedMatch"]), original));
            case "apply":
                var e = i["edit"]!.AsObject();
                var monitors = (e["monitors"]?.AsArray() ?? new JsonArray()).Select(x => x!.AsObject()).Select(m =>
                    new SettingsEdit.Monitor(Str(m["name"]), Str(m["suggestedMatch"]), Str(m["label"]), Int(m["day"]), Int(m["blindDown"]), Int(m["night"]))).ToList();
                var edit = new SettingsEdit(Str(e["source"]), OptNum(e["latitude"]), OptNum(e["longitude"]), monitors, OptStr(e["haURL"]) ?? "",
                                            OptStr(e["autoSwitch"]) ?? "", OptStr(e["sun"]) ?? "", OptStr(e["cover"]) ?? "", OptStr(e["lights"]) ?? "");
                return Saved(() => ConfigPatch.Apply(edit, original));
            case "hasComments": return ConfigPatch.HasComments(Str(i["text"]));
            default: throw new UnknownFunction(fn);
        }
    }

    static JsonNode? SuggestCases(string fn, JsonObject i) {
        switch (fn) {
            case "applyClearsOffset": return Suggest.ApplyClearsOffset(OptBool(i["mainInHA"]), Bool(i["fileWritten"]));
            case "roundToStep":
                var s = i["step"]!.AsObject();
                return Suggest.RoundToStep(Num(i["v"]), new NumberStep(Num(s["min"]), Num(s["max"]), Num(s["step"])));
            case "fmt": return Suggestion.Fmt(Num(i["v"]));
            case "sameLevels": return Suggest.SameLevels(Nums(i["a"]), Nums(i["b"]));
            case "numberStep":
                return NumberStep.Parse(Str(i["json"])) is { } st ? new JsonObject { ["min"] = st.Min, ["max"] = st.Max, ["step"] = st.Step } : null;
            default: throw new UnknownFunction(fn);
        }
    }

    // MARK: JSON values

    static bool IsNull(JsonNode? n) => n is null || n.GetValueKind() == JsonValueKind.Null;
    /// A number, or one of the texts "NaN", "Infinity", "-Infinity" (JSON has no such numbers).
    static double Num(JsonNode? n) => n?.GetValueKind() switch {
        JsonValueKind.Number => Double(n),
        JsonValueKind.String => n.GetValue<string>() switch {
            "NaN" => double.NaN, "Infinity" => double.PositiveInfinity, "-Infinity" => double.NegativeInfinity,
            var s => double.Parse(s, CultureInfo.InvariantCulture) },
        _ => double.NaN,
    };
    /// A JSON number as a double, whichever CLR number it holds (one built here may hold an int or a decimal).
    static double Double(JsonNode n) {
        var v = n.AsValue();
        if (v.TryGetValue(out double d)) return d;
        if (v.TryGetValue(out int i)) return i;
        if (v.TryGetValue(out long l)) return l;
        if (v.TryGetValue(out decimal m)) return (double)m;
        return v.GetValue<double>();
    }
    static double? OptNum(JsonNode? n) => IsNull(n) ? null : Num(n);
    static double[] Nums(JsonNode? n) => (n?.AsArray() ?? new JsonArray()).Select(Num).ToArray();
    static int Int(JsonNode? n) => (int)Num(n);
    static int? OptInt(JsonNode? n) => IsNull(n) ? null : Int(n);
    static bool Bool(JsonNode? n) => n?.GetValueKind() == JsonValueKind.True;
    static bool? OptBool(JsonNode? n) => IsNull(n) ? null : Bool(n);
    static string Str(JsonNode? n) => OptStr(n) ?? "";
    static string? OptStr(JsonNode? n) => n?.GetValueKind() == JsonValueKind.String ? n.GetValue<string>() : null;
    static JsonArray Arr(IEnumerable<double> v) => new(v.Select(x => (JsonNode)x).ToArray());

    /// The expected JSON value and the result agree: numbers to 1e-9 (relative), lists and objects member by member.
    static bool Same(JsonNode? want, JsonNode? got) {
        if (IsNull(want) || IsNull(got)) return IsNull(want) && IsNull(got);
        var w = want!.GetValueKind(); var g = got!.GetValueKind();
        switch (w) {
            case JsonValueKind.True or JsonValueKind.False: return g == w;
            case JsonValueKind.Number:
                if (g != JsonValueKind.Number) return false;
                double a = Double(want), b = Double(got);
                return a == b || Math.Abs(a - b) <= 1e-9 * Math.Max(1, Math.Abs(a));
            case JsonValueKind.String: return g == JsonValueKind.String && want.GetValue<string>() == got.GetValue<string>();
            case JsonValueKind.Array:
                var wa = want.AsArray(); var ga = got as JsonArray;
                return ga != null && ga.Count == wa.Count && wa.Zip(ga).All(p => Same(p.First, p.Second));
            case JsonValueKind.Object:
                var wo = want.AsObject(); var go = got as JsonObject;
                return go != null && go.Count == wo.Count && wo.All(p => go.ContainsKey(p.Key) && Same(p.Value, go[p.Key]));
            default: return false;
        }
    }

    static string Show(JsonNode? n) {
        try { return n?.ToJsonString() ?? "null"; } catch (ArgumentException) { return n?.ToString() ?? "null"; }
    }
}
