cask "daylit" do
  version "1.5.1"
  sha256 "714056afb90b5d9659c6ff0591396a2079ee7d4d3a255d6c80d8cbb8bc3ba4a8"

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
