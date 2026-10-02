# Homebrew cask, served straight from this repo (the repo isn't named homebrew-*, so the tap
# needs its URL):
#   brew tap ra3orblade/agentmeter https://github.com/ra3orblade/agentmeter
#   brew install --cask agentmeter
# .github/workflows/cask.yml bumps version and sha256 whenever a release is published.
cask "agentmeter" do
  version "0.1.0"
  sha256 "556c2e82d574c4814ba793d5f859eaa0fd020d401dda2fd476ec320bb5c7af07"

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
