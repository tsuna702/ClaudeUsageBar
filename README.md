# UsageBar

[한국어](README.ko.md)

A macOS menu bar app that shows your Claude and Codex usage limits.

## Features

- **Menu bar**: session (5h) and weekly usage, remaining amount, and time until reset. Each element can be turned on or off in Settings.
- **Dashboard** (left-click the icon)
  - Session and weekly limits with a burn-rate forecast from the last 45 minutes ("At this pace, empty in 2h")
  - Limit usage trend chart for the current session or week
  - Extra usage and credits (Claude extra usage, Codex credits and limit resets)
  - Today's cost (at API rates), tokens, and working time, compared with yesterday
  - Today-by-hour chart and a 30-day daily chart
  - Usage ranked by model or project (today / 7 days / 30 days)
- **Notifications** when usage crosses a warning level, and when a nearly used-up limit resets.
- **Account login** through the official CLIs (`claude auth login`, `codex login`); usage loads automatically when you finish.
- **Saved accounts**: signed-in accounts are kept in the Keychain so you can switch between them. Switching also changes the account Claude Code or Codex uses.
- **CSV export** of daily, per-model and per-project totals and limit history.
- **Update check** against GitHub Releases.
- Korean and English UI (follows the system language by default), light and dark mode, launch at login.

## Where the data comes from

| Item | Source |
|---|---|
| Claude limits | `api.anthropic.com/api/oauth/usage`, using the Claude Code login in the Keychain |
| Codex limits | `chatgpt.com/backend-api/wham/usage`, using `~/.codex/auth.json` |
| Tokens, cost, working time | Local logs in `~/.claude/projects` and `~/.codex/sessions` |

Cost is calculated at public API prices, so it is not what you pay on a subscription plan. When the Claude token expires, the app refreshes it the same way Claude Code does and saves it back to the Keychain.

## Install

Download the latest `ClaudeUsageBar-vX.Y.Z.zip` from [Releases](https://github.com/tsuna702/ClaudeUsageBar/releases), unzip it and move the app to Applications. The app is not notarized, so the first time macOS may block it. Either right-click the app and choose **Open**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/ClaudeUsageBar.app
```

## Release

Push a tag that starts with `v`. GitHub Actions builds the app and attaches a zip to a new release.

```bash
git tag v1.0.0 && git push origin v1.0.0
```

## Build

Requires Xcode Command Line Tools and macOS 14 or later.

```bash
./build.sh
open ClaudeUsageBar.app
```

To regenerate the app icon:

```bash
swift tools/make_icon.swift Resources && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns && rm -rf Resources/AppIcon.iconset
```

## Development environment variables

- `USAGE_DEBUG=1`: print loaded values to stdout.
- `USAGE_SNAPSHOT=<folder>`: save each dashboard tab as PNG (light and dark).
- `USAGE_OPEN=1`: open the dashboard right after launch.
