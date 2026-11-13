cask "daylit" do
  version "1.6.0"
  sha256 "a443df87230dbc16e462248e1aebb1e09ac721f7e3bf875775b87ec6551feddf"

  # DDC/CI monitors need m1ddc, which only exists for Apple silicon.
  on_arm do
    depends_on formula: "m1ddc"
  end

  url "https://github.com/Nachox07/daylit/releases/download/v#{version}/Daylit-mac-#{version}.zip"
  name "Daylit"
  desc "External monitor brightness that follows the sun, blinds and room lights"
  homepage "https://github.com/Nachox07/daylit"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Daylit.app"

  uninstall quit: "app.daylit.mac"

  zap trash: [
    "~/.config/daylit",
    "~/Library/Logs/Daylit",
    "~/Library/Preferences/app.daylit.mac.plist",
  ]

  caveats <<~EOS
    Daylit is not notarized by Apple, so macOS blocks the first open.
    Open System Settings → Privacy & Security, scroll to the message
    about Daylit and click "Open Anyway".

    The brightness keys need Accessibility access. The app is ad-hoc
    signed, so macOS forgets that access after every update: in
    System Settings → Privacy & Security → Accessibility, remove
    Daylit and add it again.

    `brew uninstall --zap` leaves the Home Assistant token in the
    login keychain (item "daylit-home-assistant").
  EOS
end
