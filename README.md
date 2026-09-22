# AgentUsageBar

A macOS menu-bar app for Claude, Codex, and Cursor usage.

![AgentUsageBar usage panel](docs/panel.png)

## Install

Requires macOS 14 or newer on Apple silicon.

1. Open the [latest release][latest-release] and download its DMG under Assets.
2. Drag AgentUsageBar to Applications.
3. Open AgentUsageBar once. macOS will block it because Apple has not notarized it.
4. Open System Settings → Privacy & Security, click Open Anyway, then confirm Open.

The last two steps are required only on first launch.

[latest-release]: https://github.com/andrew-cho-moment/AgentUsageBar/releases/latest

## Features

- Claude session, weekly, scoped, and monthly-budget usage
- Codex rate-limit windows, model meters, credits, and budgets
- Cursor total, API, and Auto usage with the billing-cycle reset
- Five-minute refreshes that keep the last good values during an outage
- Configurable provider folders, appearance, global Command-U shortcut, and start at login
- No row or menu-bar segment for providers that are not installed

## Data access

AgentUsageBar stores no credentials. It reads the sessions that the provider apps already
own and makes usage requests from short-lived helper processes.

| Provider | Session source | Usage endpoint |
|---|---|---|
| Claude | Keychain item `Claude Code-credentials` | `api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json` | `chatgpt.com/backend-api/wham/usage` |
| Cursor | Cursor's local SQLite database, opened read-only | `cursor.com/api/usage-summary` |

Cursor's dashboard endpoint is undocumented and may change.

## Build from source

Install the Xcode command-line tools, then run:

```bash
./setup.sh
```

The script builds, installs, and launches the app. Run it again to update without losing
settings, or run `./setup.sh --clean` to remove stale state without rebuilding.
