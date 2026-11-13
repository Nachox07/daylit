// Suggest new levels from repeated hand changes (Suggest.cs): the file of samples, working out the suggestion
// the panel shows, and its two buttons. Nothing changes a level without Apply.
using System.IO;
using System.Text.Json;

namespace Daylit;

partial class Controller {
    /// A change of levels to offer in the panel, and why the last Apply failed.
    public Suggestion? Suggestion;
    public string? SuggestError;
    /// Hand changes waiting to settle, and the settled ones (corrections.json, this PC only).
    readonly Recorder recorder = new();
    List<Sample> corrections = new();
    /// Work the suggestion out again at the end of the next tick (start, reload, a new sample, Apply, Not now).
    bool suggestDirty = true;
    /// Bumped by Apply and Not now. UpdateSuggestion drops its result when it changed during its Home Assistant
    /// reads, so a card the user already handled does not come back.
    int suggestEpoch;
    /// Per monitor, bumped where Apply clears its hand-set offset. The tick copies a monitor's hold state, awaits
    /// the write, then stores the state back: if this changed meanwhile, the copy still has the offset Apply just
    /// cleared, so the tick clears it again in its own result (and carries on normally) instead of restoring it.
    readonly Dictionary<string, int> offsetCleared = new();
    /// input_number min/max/step per entity, kept until the config reloads (a failed read is not kept).
    readonly Dictionary<string, NumberStep> stepCache = new();
    /// Entities Home Assistant answered for without min/max/step: not asked again until the config reloads.
    readonly HashSet<string> notNumber = new();
    /// What the last suggestion was worked out from: each monitor's levels, and whether Home Assistant answered.
    Dictionary<string, double[]> suggestLevels = new();
    bool? suggestFromHa;
    /// "Not now": per monitor key, no suggestion until then (Unix seconds).
    Dictionary<string, double> suggestDismissed = new();

    /// This PC's samples: %LOCALAPPDATA%\Daylit\corrections.json.
    static readonly string CorrectionsPath =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Daylit", "corrections.json");

    /// The saved samples (without those older than 14 days) and the "Not now" times. Not for snapshots.
    void LoadCorrections() {
        string? text = null;
        try { text = File.Exists(CorrectionsPath) ? File.ReadAllText(CorrectionsPath) : null; }
        catch (Exception e) { Log.Write("suggest: corrections.json unreadable, starting empty (" + e.Message + ")"); }
        var decoded = Suggest.Decode(text);
        if (!string.IsNullOrWhiteSpace(text) && (!HasSamplesList(text, out int listed) || (listed > 0 && decoded.Count == 0)))
            Log.Write("suggest: corrections.json unreadable, starting empty");   // not a samples list, or one that decodes to nothing
        corrections = Suggest.DropOld(decoded, Now);
        suggestDismissed = Settings.SuggestDismissed;
    }

    /// The file is a JSON object with a "samples" list (it may be empty).
    static bool HasSamplesList(string text, out int count) {
        count = 0;
        try {
            using var d = JsonDocument.Parse(text);
            if (d.RootElement.ValueKind != JsonValueKind.Object) return false;
            foreach (var p in d.RootElement.EnumerateObject())
                if (p.Name.Equals("samples", StringComparison.OrdinalIgnoreCase) && p.Value.ValueKind == JsonValueKind.Array) {
                    count = p.Value.GetArrayLength();
                    return true;
                }
            return false;
        } catch (JsonException) { return false; }
    }

    void SaveCorrections() {
        corrections = Suggest.DropOld(corrections, Now);
        try {
            Directory.CreateDirectory(Path.GetDirectoryName(CorrectionsPath)!);
            string tmp = CorrectionsPath + ".tmp";
            File.WriteAllText(tmp, Suggest.Encode(corrections));
            File.Move(tmp, CorrectionsPath, true);
        } catch (Exception e) { Log.Write("suggest: could not save corrections.json: " + e.Message); }
    }

    /// The monitor's input_number for a level, when the source is Home Assistant and one is configured.
    string? HaEntity(Level l, Mon m) {
        if (Source != Source.HomeAssistant || m.Spec?.HomeAssistant is not { } h) return null;
        string? e = l switch { Level.Day => h.Day, Level.BlindDown => h.BlindDown, Level.Night => h.Night, _ => h.NightLights };
        return e != null && Config.IsEntityId(e) ? e : null;
    }

    /// Whether Home Assistant gave this level this tick (it is not down and the helper reads 0 or more).
    static bool HaLevelAvailable(Level l, int i, Inputs s, bool haDown) =>
        !haDown && s.FromHa is { } raw && i < raw.Length && raw[i].Length > (int)l && raw[i][(int)l] >= 0;

    /// Whether some of the monitor's levels should come from Home Assistant but are not available this tick:
    /// Home Assistant is down (the sun stands in), or a configured helper reads below 0. Samples recorded
    /// with Home Assistant's levels must not be judged stale against local ones then.
    /// The nightLights helper is part of the levels snapshot too (row index 3).
    bool HaLevelsUnavailable(Mon m, int i, Inputs s, bool haDown) =>
        LevelText.All.Any(l => HaEntity(l, m) != null && !HaLevelAvailable(l, i, s, haDown));

    /// What a level can be stored as now: a whole number for a local level, the input_number's own step, or
    /// null when it comes from Home Assistant and is unavailable. Retry is true when the level is available
    /// this tick but its step could not be read: try again next tick.
    async Task<(NumberStep? Step, bool Retry)> StepFor(Level l, Mon m, int i, Inputs s, bool haDown) {
        if (HaEntity(l, m) is not { } e) return (NumberStep.Whole, false);
        if (!HaLevelAvailable(l, i, s, haDown)) return (null, false);
        if (stepCache.TryGetValue(e, out var cached)) return (cached, false);
        if (notNumber.Contains(e)) return (null, false);
        var (read, answered) = await HAClient.GetNumberStep(Cfg, e);
        if (read is { } got) { stepCache[e] = got; return (got, false); }
        if (!answered) return (null, true);
        notNumber.Add(e);
        Log.Write($"suggest: {e} is not an input_number, its level is not offered");
        return (null, false);
    }

    /// At the end of a tick: works the suggestion out again when something changed. The first monitor with one
    /// is shown; the next shows after it is handled.
    async Task UpdateSuggestion(Inputs s, Mon[] mons, bool haDown) {
        var current = new Dictionary<string, double[]>();
        for (int i = 0; i < mons.Length && i < s.Levels.Length; i++) current[mons[i].Key] = s.Levels[i];
        bool fromHa = !haDown && Source == Source.HomeAssistant;
        bool same = current.Count == suggestLevels.Count
                    && current.All(kv => suggestLevels.TryGetValue(kv.Key, out var lv) && Suggest.SameLevels(lv, kv.Value));
        if (!same || fromHa != suggestFromHa) suggestDirty = true;
        if (!suggestDirty) return;
        suggestDirty = false; suggestLevels = current; suggestFromHa = fromHa;
        double now = Now;
        // A monitor whose Home Assistant levels are unavailable this tick is left out: DropStale keeps the samples
        // of monitors it does not know, so they are not deleted for good just because local levels stand in for a while.
        var known = new Dictionary<string, double[]>(current);
        for (int i = 0; i < mons.Length && i < s.Levels.Length; i++)
            if (HaLevelsUnavailable(mons[i], i, s, haDown)) known.Remove(mons[i].Key);
        var kept = Suggest.DropOld(Suggest.DropStale(corrections, known), now);
        if (kept.Count != corrections.Count) { corrections = kept; SaveCorrections(); }
        int epoch = suggestEpoch;
        Suggestion? found = null;
        for (int i = 0; i < mons.Length && i < s.Levels.Length; i++) {
            var m = mons[i];
            if (!kept.Any(x => x.Monitor == m.Key)) continue;
            // Steps are only needed for the levels the samples can tell apart (the others are never proposed).
            var mine = kept.Where(x => x.Monitor == m.Key && Suggest.SameLevels(x.Levels, s.Levels[i])).ToList();
            var cand = Suggest.Candidates(mine, t: Cfg.Tuned);
            // A monitor without nightLights may be offered one beside a lower night, but only when the room lights
            // come from Home Assistant: without them the level would never be used.
            bool hasNl = Rules.NightLightsLevel(s.Levels[i]) != null;
            bool canAddNl = !hasNl && Source == Source.HomeAssistant && Cfg.HomeAssistant?.Lights is { } lightsEntity
                            && Config.IsEntityId(lightsEntity) && cand.Contains(Level.Night);
            var steps = new NumberStep?[4];
            foreach (var l in LevelText.All) {
                if (l == Level.NightLights && !hasNl && !canAddNl) { steps[(int)l] = null; continue; }
                if (!cand.Contains(l) && !(l == Level.NightLights && canAddNl)) { steps[(int)l] = NumberStep.Whole; continue; }
                var r = await StepFor(l, m, i, s, haDown);
                if (r.Retry) suggestDirty = true;   // Home Assistant did not answer: work it out again next tick
                steps[(int)l] = r.Step;
            }
            // Apply / Not now was used while waiting, or the monitor went away: this answer is stale.
            if (epoch != suggestEpoch || !Mons.Contains(m)) { suggestDirty = true; return; }
            double? until = suggestDismissed.TryGetValue(m.Key, out var u) ? u : null;
            var sg = Suggest.SuggestionFor(m.Key, kept, s.Levels[i], steps, now, until, Cfg.Tuned);
            if (sg != null) { found = sg; break; }
        }
        if (found == Suggestion) return;   // records compare by value (Suggestion.Equals)
        if (found is { } f && mons.FirstOrDefault(x => x.Key == f.Monitor) is { } fm) Log.Write(f.LogLine(fm.Label));
        Suggestion = found;
    }

    /// Apply: writes each proposed level (its input_number in Home Assistant, or the local level in config.json),
    /// then clears the monitor's hand-set offset, which would otherwise be applied again on top of the new level.
    /// A failed write keeps the ones that worked and shows in the panel's problem line.
    public async void ApplySuggestion() {
        try {
            if (Suggestion is not { } sg || Mons.FirstOrDefault(x => x.Key == sg.Monitor) is not { } m) return;
            Suggestion = null; SuggestError = null; suggestEpoch++;
            if (panel.IsVisible) panel.Sync();   // the card hides at once
            var local = new Dictionary<string, int>();
            var failed = new List<string>();
            foreach (var ch in sg.Changes) {
                if (HaEntity(ch.Level, m) is { } e) {
                    if (await HAClient.SetNumber(Cfg, e, ch.To) is { } why) failed.Add($"{e} failed: {why}");
                } else local[ch.Level.Key()] = (int)Math.Round(ch.To, MidpointRounding.AwayFromZero);
            }
            bool wroteFile = false;
            if (local.Count > 0) {
                try {
                    string? original = File.Exists(Config.PathName) ? File.ReadAllText(Config.PathName) : null;
                    if (original != null && ConfigPatch.HasComments(original))
                        throw new InvalidDataException("it has comments, which saving would remove; set the level in Settings instead");
                    string text = ConfigPatch.SetLevels(local, m.D.Friendly, ConfigPatch.SuggestMatch(m.D.Friendly), original);
                    Directory.CreateDirectory(Config.Dir);
                    string tmp = Config.PathName + ".tmp";
                    File.WriteAllText(tmp, text);
                    File.Move(tmp, Config.PathName, true);
                    wroteFile = true;
                } catch (Exception ex) { failed.Add("config.json failed: " + ex.Message); }
            }
            offsetCleared[sg.Monitor] = offsetCleared.GetValueOrDefault(sg.Monitor) + 1;   // a tick in flight merges this clear into its own result
            var cleared = Suggest.AfterApply(new Hold(m.RemoteSeen, m.LastSet, m.LastTarget, m.Offset, m.OffsetSun, m.OffsetAt, m.RemoteValue));
            (m.LastSet, m.Offset, m.OffsetSun, m.OffsetAt) = (cleared.LastSet, cleared.Offset, cleared.OffsetSun, cleared.OffsetAt);
            m.Manual = false;
            recorder.Drop(sg.Monitor);
            foreach (var f in failed) Log.Write($"suggest: {m.Label} {f}");
            if (failed.Count == 0) Log.Write($"suggest: {m.Label} applied");
            else SuggestError = "Could not apply the suggestion: " + string.Join("; ", failed);
            suggestDirty = true;
            string? applyError = SuggestError;
            if (wroteFile) { Reload(); SuggestError = applyError; if (panel.IsVisible) panel.Sync(); } else await Tick("suggestion applied");   // Reload: the new local level is in the file now
        } catch (Exception err) { Log.Write("suggest: " + err); }
    }

    /// Not now: no suggestion for this monitor for 7 days, remembered across restarts.
    public void DismissSuggestion() {
        if (Suggestion is not { } sg) return;
        double now = Now;
        suggestDismissed[sg.Monitor] = now + Suggest.NotNow;
        suggestDismissed = suggestDismissed.Where(kv => kv.Value > now).ToDictionary(kv => kv.Key, kv => kv.Value);   // expired entries go
        suggestEpoch++;
        Settings.SuggestDismissed = suggestDismissed;
        Log.Write($"suggest: {Mons.FirstOrDefault(x => x.Key == sg.Monitor)?.Label ?? "a monitor"} not now");
        Suggestion = null; SuggestError = null; suggestDirty = true;
        if (panel.IsVisible) panel.Sync();   // the card hides at once
        _ = Tick("not now");
    }
}
