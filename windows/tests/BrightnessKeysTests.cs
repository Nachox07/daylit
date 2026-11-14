using Xunit;

namespace Daylit.Tests;

public class BrightnessKeysTests {
    static readonly ushort[] None = [], Up = [BrightnessKeys.Up], Down = [BrightnessKeys.Down];

    [Fact]
    public void APressActsOnceAndTheReleaseDoesNothing() {
        Assert.True(BrightnessKeys.Pressed(None, Up));
        Assert.Null(BrightnessKeys.Pressed(Up, Up));      // the same report again while held
        Assert.Null(BrightnessKeys.Pressed(Up, None));    // release
        Assert.False(BrightnessKeys.Pressed(None, Down));
    }

    [Fact]
    public void ReadsTheUsageFromAPlainConsumerReport() {
        Assert.Equal(Up, BrightnessKeys.FromBytes([0x02, 0x6F, 0x00, 0x00, 0x00]));
        Assert.Equal(Down, BrightnessKeys.FromBytes([0x02, 0x70, 0x00, 0x00, 0x00]));
        Assert.Empty(BrightnessKeys.FromBytes([0x02, 0x00, 0x00, 0x00, 0x00]));
        Assert.Empty(BrightnessKeys.FromBytes([0x02, 0xE9, 0x00]));   // volume up is not a brightness key
    }
}
