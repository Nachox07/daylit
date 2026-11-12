using Xunit;

namespace Daylit.Tests;

public class ShortcutRuleTests {
    [Fact]
    public void DistinctCombinationsDoNotClash() {
        Assert.Null(ShortcutRule.Clash([(3, 0x21), (3, 0x22), (3, 0x44)]));
    }

    [Fact]
    public void TheFirstPairWithTheSameKeyAndModifiersIsReported() {
        var c = ShortcutRule.Clash([(3, 0x21), (3, 0x22), (3, 0x21)]);
        Assert.NotNull(c);
        Assert.Equal(0, c!.Value.Item1);
        Assert.Equal(2, c.Value.Item2);
    }

    [Fact]
    public void TheSameKeyWithOtherModifiersIsNotAClash() {
        Assert.Null(ShortcutRule.Clash([(3, 0x44), (2, 0x44)]));
    }
}
