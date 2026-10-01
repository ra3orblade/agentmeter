# Agent Meter

A native macOS menu bar app that shows what your AI coding agents are spending, across all of them, as it happens.

It reads the logs the agents already write on your machine. You don't need an account, an API key, or a proxy, and it sends no telemetry.

| Agent | Where it reads |
|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` (respects `CLAUDE_CONFIG_DIR`) |
| Codex CLI | `~/.codex/sessions/**/rollout-*.jsonl` (respects `CODEX_HOME`) |
| Gemini CLI | `~/.gemini/tmp/*/chats/*.jsonl` |
| Grok CLI | `~/.grok/sessions/*/*/updates.jsonl` |
| opencode | `~/.local/share/opencode/opencode*.db` (respects `XDG_DATA_HOME`; uses opencode's own cost) |

What it shows:

- **Menu bar:** a gauge and today's spend. You can switch to cost only or gauge only (••• menu → *Menu bar shows*). The needle compares today's spend with your daily budget if you set one; otherwise it compares with a typical day (the average of the last 7 days), so an ordinary day points straight up.
- **Dropdown:** today, 7 days or 30 days, split by agent and by project (git worktrees count toward their repo). Also lists sessions that billed a turn in the last 15 minutes, by title, and a 30-day chart.
- **Daily budget alert:** one notification per day when spend crosses the threshold.

Costs are **API list prices**. If you're on a subscription (Claude Max, ChatGPT Pro, …), they show what the same usage would cost on the API, not what you paid.

## Install

Requirements: macOS 14+ and Swift 6 (the Command Line Tools are enough; Xcode isn't required).

```sh
tools/bundle.sh                 # → dist/AgentMeter.app
open dist/AgentMeter.app        # or move it to /Applications first
```

The first launch indexes the last 90 days of logs. That takes a few seconds per GB, and after that updates are incremental. On a notched MacBook with a full menu bar, a new item can land under the notch: ⌘-drag it somewhere visible.

## How it works

- `Scanner` reads each log from where it last stopped and only consumes complete lines. Cursors and every parsed turn live in `~/Library/Application Support/AgentMeter/meter.db`, a cache you can delete at any time; it rebuilds from the logs.
- FSEvents reports which files changed, so only those are read. A full walk runs once a minute as a safety net.
- Turn ids are stable (Claude's `message.id`, Codex's event fingerprint, …), so re-reading a file overwrites rows instead of double counting. That also covers Claude's streamed responses, where the last usage wins.

## Prices

There are three layers, and later layers win:

1. **Snapshot:** generated from [LiteLLM's price list](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json) at build time (`tools/snapshot-prices.py`), on top of a short hand-kept list of family prefixes so a brand-new model still gets its family's price.
2. **Update prices from LiteLLM** (gear menu): downloads the latest list. This is the only network request the app makes, and it only happens when you click it.
3. **Your overrides:** `pricing.json` in the support folder, in USD per million tokens:

   ```json
   { "my-model": { "input": 1.0, "output": 2.0, "cacheWrite": 1.25, "cacheRead": 0.1 } }
   ```

Model ids match by longest prefix. Turns from a model with no price still count tokens and are flagged in the dropdown.

## Develop

```sh
swift build
tools/test.sh                                   # Swift Testing (works with the Command Line Tools)
.build/debug/AgentMeter --snapshot out.png      # render the dropdown with live data to a PNG (--dark too)
tools/snapshot-prices.py                        # refresh the compiled-in price table
```

The app icon and the menu bar glyph are both drawn by `Sources/AgentMeter/Logo.swift`. `tools/bundle.sh` renders the icon set from it (`AgentMeter --iconset <dir>`), so there is no image file to keep in sync.

Layout: `Sources/MeterCore` is the logic (parsers, pricing, SQLite cache, scanner, report, FSEvents) and has no UI. `Sources/AgentMeter` is the SwiftUI app.

## License

Apache-2.0
