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
}
