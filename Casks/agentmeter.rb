# Homebrew cask, served straight from this repo (the repo isn't named homebrew-*, so the tap
# needs its URL):
#   brew tap ra3orblade/agentmeter https://github.com/ra3orblade/agentmeter
#   brew install --cask agentmeter
# .github/workflows/cask.yml bumps version and sha256 whenever a release is published.
cask "agentmeter" do
  version "0.2.0"
  sha256 "5600315a62195b40ed5a4565ddcaf33e5b59c48e674122100da0ab18c401c720"

  url "https://github.com/ra3orblade/agentmeter/releases/download/v#{version}/AgentMeter-#{version}.zip"
  name "Agent Meter"
  desc "Menu bar spend meter for AI coding agents"
  homepage "https://github.com/ra3orblade/agentmeter"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "AgentMeter.app"

  uninstall quit: "dev.agentmeter.AgentMeter"

  zap trash: [
    "~/Library/Application Support/AgentMeter",
    "~/Library/Caches/dev.agentmeter.AgentMeter",
    "~/Library/HTTPStorages/dev.agentmeter.AgentMeter",
    "~/Library/Preferences/dev.agentmeter.AgentMeter.plist",
  ]
end
