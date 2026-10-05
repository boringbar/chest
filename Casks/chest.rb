cask "chest" do
  version "0.1.1"
  sha256 "66e49ae43eba51e43b4a68ae957bba03a16266aa2ac51be2da847c0a8caf6860"

  url "https://files.boringbar.app/chest/Chest-#{version}.zip"
  name "Chest"
  desc "Hide menu bar items away into a separate space"
  homepage "https://github.com/boringbar/chest"

  livecheck do
    url "https://files.boringbar.app/chest/appcast.xml"
    strategy :sparkle, &:short_version
  end

  # Chest updates itself with Sparkle.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :golden_gate

  app "Chest.app"

  # A normal quit makes Chest put every hidden item back in the menu bar before it goes.
  uninstall quit: "app.boringbar.chest"

  zap trash: [
    "~/Library/Caches/app.boringbar.chest",
    "~/Library/HTTPStorages/app.boringbar.chest",
    "~/Library/Preferences/app.boringbar.chest.plist",
  ]

  caveats <<~EOS
    Chest needs Accessibility and Full Disk Access, and asks for both on first launch.
    After switching on Full Disk Access, choose "Quit & Reopen" when macOS asks.
  EOS
end
