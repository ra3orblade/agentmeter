# Changelog

## [0.1.0] - 2026-10-01

The first release.

- Shows today's spend in the menu bar, as a gauge, a cost or both. The needle reads against your daily budget or, without one, against a typical day.
- The dropdown covers Today, 7 days and 30 days, split by agent and by project (worktrees count toward their repo). It also has active sessions by title and a 30-day chart you can hover.
- Reads Claude Code, Codex CLI, Gemini CLI, Grok CLI and opencode logs directly. It needs no account, sends no telemetry, and opens every log read-only.
- Updates come from FSEvents and only read what's new; it idles well under 1% CPU.
- Prices come from a LiteLLM snapshot built into the app. You can update them on demand (the only network request) and override them per model.
- Daily budget notification and launch at login.
- Universal binary (Apple silicon + Intel), signed with Developer ID and notarized.
