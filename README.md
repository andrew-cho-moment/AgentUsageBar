# AgentUsageBar

A macOS menu bar app showing Claude and Codex usage, including how much of a monthly
dollar budget has been spent.

```
✳ 16%/6%   >_ 22%
```

Each provider appears only when you are signed in to it. Numbers are the rate-limit
windows that provider actually reports; the dollar budget lives in the popover.

Private fork of [Artzainnn/ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar)
with Codex support ported from
[Artzainnn/CodexUsageBar](https://github.com/Artzainnn/CodexUsageBar).

## What it shows

**Claude** — session (5 hour), weekly (7 day), any model-scoped weekly caps, and:

```
Monthly budget                              Manage →
████████████████████░░░░░░░░░░░░  61%
$611.53 of $1,000.00 · $388.47 left · 61%
```

**Codex** — whichever rate-limit windows the account reports, plus per-model meters
like GPT-5.3-Codex-Spark once they rise above 1%.

**Claude service status** — a severity dot and, during an incident, an expandable panel.
Only the services you tick in Settings count.

## Authentication

No cookies to paste. Both providers are read from credentials their CLIs already wrote:

| Provider | Source | Endpoint |
|---|---|---|
| Claude | Keychain item `Claude Code-credentials` (written by `claude login`) | `api.anthropic.com/api/oauth/usage` |
| Codex  | `~/.codex/auth.json` (written by `codex login`) | `chatgpt.com/backend-api/wham/usage` |

On first launch macOS asks permission to read Claude Code's Keychain item. Click
**Always Allow**.

Codex tokens are refreshed on a 401 against `auth.openai.com/oauth/token` and kept **in
memory only** — `~/.codex/auth.json` stays owned by the CLI and is never written to.
This app persists no credential of its own.

## Build

```bash
cd app
./make_signing_cert.sh          # once: creates a stable local signing identity
CODESIGN_IDENTITY="AgentUsageBar Dev" ./build.sh
```

Then drag `app/build/AgentUsageBar.app` to `/Applications`.

`./build.sh` alone works and signs ad-hoc, but ad-hoc signatures change on every build,
which invalidates the Keychain grant each time. The certificate exists to give the app a
stable identity; it is not a Developer ID and cannot be notarized or distributed.

Requires macOS 14+. Builds a universal binary.

## Budgets

The Claude budget comes from the API. It is read from `spend.limit` / `spend.used`
(`{amount_minor, currency, exponent}` triples), falling back to `extra_usage`
(`monthly_limit`, `used_credits`).

If a provider reports spend but no limit, Settings offers a **Monthly budget** field to
supply one. A budget filled in this way is labelled as yours, not as billed truth. The
field is hidden for providers that report their own limit.

**Codex budgets are credits, never dollars.** Codex exposes a monthly cap at
`spend_control.individual_limit`, but only on Business/Edu/Enterprise seats, and it is
credit-denominated with no currency field and no OpenAI-published credit-to-dollar rate.
It is rendered as `7,761 of 100,000 credits`, and it is `null` on personal Plus/Pro
accounts.

## Notifications

Claude outage alerts only, and only for the services you track.

`UNUserNotificationCenter` requires an Apple-issued Team ID, which a self-signed build
does not have, so delivery falls back to `osascript`. Alerts then appear attributed to
Script Editor rather than to this app. The native path is preferred automatically if the
app is ever signed with a Developer ID.

## Menu bar behavior

Each signed-in provider gets its own mark followed by its percentages: `✳` for Claude,
`>_` for Codex. Both always show, so a number is never left without a label.

`>_` is the Codex CLI's own motif. OpenAI's hexagonal knot was tried first and collapses
into a blob at 14pt, where the interlacing that carries the shape is finer than a pixel.

The app makes no attempt to sit beside Claude Desktop's or ChatGPT's own menu bar items.
Claude Desktop publishes its slot as `NSStatusItem Preferred Position Item-0`, so
following it worked, but ChatGPT publishes nothing and macOS reports every menu bar
window as owned by Control Center, so its position cannot be read without an
Accessibility grant this app does not ask for. Following one vendor and not the other
was worse than following neither.

## Diagnostics

Nothing is logged by default: both providers return bearer-authenticated account data,
and the unified log is readable by any process running as you.

```bash
launchctl setenv AGENTUSAGEBAR_DEBUG 1
open /Applications/AgentUsageBar.app
/usr/bin/log show --last 5m --predicate 'subsystem == "com.andrewcho.agentusagebar"'
launchctl unsetenv AGENTUSAGEBAR_DEBUG
```

Use `/usr/bin/log`; `log` is a zsh builtin that shadows it.

## Removed from upstream

- The update and announcement channel, which polled the upstream author's `latest.json`
  every 3 hours and rendered author-controlled banner text, buttons and OS notification
  titles on your machine.
- The donation link.
- Session and budget threshold notifications.
- Cookie storage. Upstream kept a full claude.ai session cookie in plaintext
  `UserDefaults`, readable by any process running as you.
- The Accessibility permission prompt. Carbon hot keys never needed it.

## Limits

Both providers use internal, undocumented endpoints that can change without notice. The
Claude OAuth endpoint is the one Claude Code itself uses, so it is the more stable.

When a schema change does land, unrecognized values are surfaced in the popover rather
than silently skipped.
