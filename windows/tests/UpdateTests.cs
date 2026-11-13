using System.Text.Json.Nodes;
using Xunit;

namespace Daylit.Tests;

// The same cases as mac/Tests/DaylitCoreTests/UpdateTests.swift.
public class UpdateVersionTests {
    [Fact]
    public void VersionsParseWithOrWithoutAV() {
        Assert.Equal(new[] { 1, 5, 1 }, UpdateCheck.Parse("1.5.1"));
        Assert.Equal(new[] { 1, 5, 1 }, UpdateCheck.Parse("v1.5.1"));
        Assert.Equal(new[] { 2, 0 }, UpdateCheck.Parse(" V2.0 "));
        Assert.Equal(new[] { 10 }, UpdateCheck.Parse("10"));
    }

    [Theory]
    [InlineData("")] [InlineData("v")] [InlineData("1.5-beta")] [InlineData("1..5")] [InlineData("1.5.")] [InlineData("one.two")]
    [InlineData("1.2.3.4.5")] [InlineData("1.5 beta")] [InlineData("-1.2")] [InlineData("１.２")]
    public void TextThatIsNotAVersionDoesNotParse(string s) => Assert.Null(UpdateCheck.Parse(s));

    [Fact]
    public void ComparisonIsNumericNotAlphabetical() {
        Assert.True(UpdateCheck.IsNewer("1.10.0", "1.9.9"));
        Assert.True(UpdateCheck.IsNewer("v2.0.0", "1.99.99"));
        Assert.True(UpdateCheck.IsNewer("1.5.1", "1.5"));
        Assert.False(UpdateCheck.IsNewer("1.9.9", "1.10.0"));
    }

    [Fact]
    public void TheSameVersionIsNotNewer() {
        Assert.False(UpdateCheck.IsNewer("1.5.1", "v1.5.1"));
        Assert.False(UpdateCheck.IsNewer("1.5", "1.5.0"));
    }

    [Fact]
    public void AnythingThatIsNotAVersionIsNeverNewer() {
        Assert.False(UpdateCheck.IsNewer("nightly", "1.0.0"));
        Assert.False(UpdateCheck.IsNewer("2.0.0", "garbage"));
    }

    [Fact]
    public void LocalBuildsAreDevBuilds() {
        foreach (var v in new string?[] { null, "", "0.0.0", "0", "dev", "abc" }) Assert.True(UpdateCheck.IsDevBuild(v), v ?? "null");
        Assert.False(UpdateCheck.IsDevBuild("1.5.1"));
        Assert.False(UpdateCheck.IsDevBuild("0.0.1"));
    }

    [Fact]
    public void TheUserAgentCarriesOnlyTheAppAndItsVersion() {
        Assert.Equal("Daylit/1.5.1", UpdateCheck.UserAgent("1.5.1"));
        Assert.Equal("Daylit/dev", UpdateCheck.UserAgent("0.0.0"));
        Assert.Equal("Daylit/dev", UpdateCheck.UserAgent(null));
    }
}

public class UpdateAvailableTests {
    static UpdateCheck.Release Rel(string tag, string body = "", bool draft = false, bool pre = false) =>
        new(tag, "https://github.com/Nachox07/daylit/releases/tag/" + tag, body, draft, pre);
    static string Body(params string[] items) =>
        "## What's Changed\n" + string.Join("\n", items.Select(i => $"* {i} by @someone in https://github.com/Nachox07/daylit/pull/1"))
        + "\n\n\n**Full Changelog**: https://github.com/Nachox07/daylit/compare/v1.0.0...v1.0.1\n";

    [Fact]
    public void ANewerReleaseIsAvailableWithItsPageAndVersion() {
        var a = UpdateCheck.Find("1.5.0", [Rel("v1.5.1", Body("Fix the slider")), Rel("v1.5.0")]);
        Assert.Equal("1.5.1", a?.Version);
        Assert.Equal("https://github.com/Nachox07/daylit/releases/tag/v1.5.1", a?.Url);
        Assert.Equal(["Fix the slider"], a!.Changes);
    }

    [Fact]
    public void WhenTheRunningVersionIsTheLatestNothingIsAvailable() =>
        Assert.Null(UpdateCheck.Find("1.5.1", [Rel("v1.5.1", Body("A")), Rel("v1.5.0", Body("B"))]));

    [Fact]
    public void ANewerRunningVersionSeesNothing() => Assert.Null(UpdateCheck.Find("2.0.0", [Rel("v1.5.1")]));

    [Fact]
    public void DevBuildsNeverSeeAnUpdate() {
        Assert.Null(UpdateCheck.Find("0.0.0", [Rel("v9.0.0")]));
        Assert.Null(UpdateCheck.Find(null, [Rel("v9.0.0")]));
    }

    [Fact]
    public void DraftsPrereleasesAndOddTagsAreSkipped() {
        var a = UpdateCheck.Find("1.0.0", [Rel("v3.0.0", draft: true), Rel("v2.0.0", pre: true), Rel("nightly"), Rel("v1.1.0", Body("Real"))]);
        Assert.Equal("1.1.0", a?.Version);
        Assert.Equal(["Real"], a!.Changes);
    }

    [Fact]
    public void SkippingVersionsCollectsEveryNewerReleaseNewestFirst() {
        var a = UpdateCheck.Find("1.4.0", [Rel("v1.4.0", Body("Old")), Rel("v1.6.0", Body("Six a", "Six b")), Rel("v1.5.0", Body("Five")), Rel("v1.3.0", Body("Older"))]);
        Assert.Equal("1.6.0", a?.Version);
        Assert.Equal(["Six a", "Six b", "Five"], a!.Changes);
    }

    [Fact]
    public void AReleaseWithoutAChangesSectionAddsNothing() {
        var a = UpdateCheck.Find("1.0.0", [Rel("v1.2.0", Body("Two")), Rel("v1.1.0", "Bug fixes.\n\n## Install\nUnzip it.")]);
        Assert.Equal(["Two"], a!.Changes);
    }
}

public class UpdateNotesTests {
    const string Generated = """
        ## What's Changed
        * Mac: ask for Accessibility once, then wait quietly by @Nachox07 in https://github.com/Nachox07/daylit/pull/70
        * Settings: Instant updates switch for push (both apps) by @Nachox07 in https://github.com/Nachox07/daylit/pull/71


        **Full Changelog**: https://github.com/Nachox07/daylit/compare/v1.5.0...v1.5.1

        ## Install
        * Download the zip
        """;

    [Fact]
    public void TheBulletsUnderWhatsChangedAreTheChangesWithoutTheirAttribution() =>
        Assert.Equal(["Mac: ask for Accessibility once, then wait quietly", "Settings: Instant updates switch for push (both apps)"],
                     UpdateCheck.Changes(Generated.Replace("\r\n", "\n")));

    [Fact]
    public void WindowsLineEndingsReadTheSame() =>
        Assert.Equal(2, UpdateCheck.Changes(Generated.Replace("\r\n", "\n").Replace("\n", "\r\n")).Count);

    [Fact]
    public void ABodyWithoutTheSectionHasNoChanges() {
        Assert.Empty(UpdateCheck.Changes(""));
        Assert.Empty(UpdateCheck.Changes("Bug fixes.\n* Not under the heading\n## Install\n* Unzip"));
    }

    [Fact]
    public void TheListEndsAtTheNextHeading() =>
        Assert.Equal(["One"], UpdateCheck.Changes("## What's Changed\n* One\n## New Contributors\n* @x made their first contribution"));

    [Fact]
    public void BulletsWithoutAnAttributionAreKeptAsTheyAre() =>
        Assert.Equal(["Faster start", "Written by hand"], UpdateCheck.Changes("## What's Changed\n* Faster start\n* Written by hand"));

    [Fact]
    public void SeveralAuthorsAreDroppedToo() =>
        Assert.Equal(["Shared work"], UpdateCheck.Changes("## What's Changed\n* Shared work by @a and @b in https://github.com/x/y/pull/2"));

    [Fact]
    public void MalformedTextGivesNoChangesOrOnlyTheBulletsThatAreThere() {
        Assert.Empty(UpdateCheck.Changes("## What's Changed"));
        Assert.Empty(UpdateCheck.Changes("## What's Changed\n\n\n"));
        Assert.Empty(UpdateCheck.Changes("## What's Changed\n*\n* \n*No space\n* Real"));
        Assert.Equal(["Kept"], UpdateCheck.Changes("##What's changed\n* by @x in https://e.com/1\n* Kept"));
        Assert.Empty(UpdateCheck.Changes("\0<script>## What's Changed\n* A"));
    }

    [Fact]
    public void AVeryLongChangeIsShortened() {
        var c = UpdateCheck.Changes("## What's Changed\n* " + new string('x', 500));
        Assert.Equal(200, c[0].Length);
        Assert.EndsWith("…", c[0]);
    }

    [Fact]
    public void ThePanelShowsEightChangesAndCountsTheRest() {
        var all = Enumerable.Range(1, 11).Select(i => $"Change {i}").ToList();
        var (items, more) = UpdateCheck.Shown(all);
        Assert.Equal(all.Take(8), items);
        Assert.Equal(3, more);
        Assert.Equal(0, UpdateCheck.Shown(["One"]).More);
    }

    [Fact]
    public void GitHubsAnswerIsReadIntoReleases() {
        const string json = """
            [ { "tag_name": "v1.5.1", "html_url": "https://github.com/Nachox07/daylit/releases/tag/v1.5.1", "draft": false, "prerelease": false, "body": "## What's Changed\n* A" },
              { "tag_name": "v1.6.0-rc1", "html_url": "https://github.com/Nachox07/daylit/releases/tag/v1.6.0-rc1", "prerelease": true, "body": null },
              { "tag_name": "v9.9.9", "html_url": "javascript:alert(1)" },
              { "name": "no tag" } ]
            """;
        var r = UpdateCheck.Releases(json)!;
        Assert.Equal(["v1.5.1", "v1.6.0-rc1"], r.Select(x => x.Tag));
        Assert.Equal("", r[1].Body);
        Assert.True(r[1].Prerelease);
        Assert.Null(UpdateCheck.Releases("""{"message": "API rate limit exceeded"}"""));
        Assert.Null(UpdateCheck.Releases("not json"));
    }
}

public class UpdateLineTests {
    static readonly UpdateCheck.Available A = new("1.6.0", "https://github.com/Nachox07/daylit/releases/tag/v1.6.0", []);

    [Fact] public void ANewVersionShowsTheLine() => Assert.True(UpdateCheck.ShowLine(A, null, checkUpdates: true, manual: false));
    [Fact] public void NothingAvailableShowsNothingEvenWhenAsked() => Assert.False(UpdateCheck.ShowLine(null, null, checkUpdates: true, manual: true));
    [Fact] public void NotNowHidesThatVersion() => Assert.False(UpdateCheck.ShowLine(A, "1.6.0", checkUpdates: true, manual: false));
    [Fact] public void ANewerVersionThanTheOnePutOffShowsAgain() => Assert.True(UpdateCheck.ShowLine(A, "1.5.1", checkUpdates: true, manual: false));
    [Fact] public void WithChecksOffTheLineStaysHidden() => Assert.False(UpdateCheck.ShowLine(A, null, checkUpdates: false, manual: false));
    [Fact] public void CheckingFromTheMenuShowsItEvenWhenOffOrPutOff() => Assert.True(UpdateCheck.ShowLine(A, "1.6.0", checkUpdates: false, manual: true));
}

public class UpdateSettingsEditTests {
    static JsonObject Root(SettingsEdit e, string? original) => (JsonObject)JsonNode.Parse(ConfigPatch.Apply(e, original))!;
    static SettingsEdit Edit(bool? on, bool editable = true) =>
        new("off", null, null, []) { CheckUpdatesEditable = editable, CheckUpdates = on };
    static (Config cfg, string? error) Load(string json) {
        var p = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".json");
        File.WriteAllText(p, json);
        return Config.Load(p);
    }

    [Fact]
    public void TurningChecksOffWritesFalseAndKeepsTheRest() {
        var r = Root(Edit(false), """{ "futureKey": 1 }""");
        Assert.False((bool)r["checkUpdates"]!);
        Assert.Equal(1, (int)r["futureKey"]!);
    }

    [Fact]
    public void TurningChecksOnRemovesTheKey() {
        Assert.Null(Root(Edit(true), """{ "checkUpdates": false }""")["checkUpdates"]);
        Assert.Null(Root(Edit(null), null)["checkUpdates"]);
    }

    [Fact]
    public void TheKeyIsKeptWhenTheWindowDoesNotShowTheSwitch() =>
        Assert.False((bool)Root(Edit(null, editable: false), """{ "checkUpdates": false }""")["checkUpdates"]!);

    [Fact]
    public void ASavedOffReadsBackAsOffAndMissingAsDefault() {
        Assert.False(Load(ConfigPatch.Apply(Edit(false), null)).cfg.CheckUpdates);
        Assert.Null(Load(ConfigPatch.Apply(Edit(true), null)).cfg.CheckUpdates);
    }

    [Fact]
    public void ABrokenConfigStillKeepsChecksOff() {
        var (c, err) = Load("""{ "checkUpdates": false, "location": { "latitude": 200, "longitude": 0 } }""");
        Assert.NotNull(err);
        Assert.False(c.CheckUpdates);
    }
}
