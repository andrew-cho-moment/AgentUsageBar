# AgentUsageBar

AgentUsageBar is an Apple-silicon macOS menu-bar app for Claude and Codex usage.

```text
✳ 16%/6%   >_ 22%
```

The resident process is a 106 KB Objective-C executable. It keeps only fixed-size C
records, one status item, and an optional manually drawn panel. Swift, URLSession, JSON
decoding, Keychain access, and provider response objects live in helper processes that
exit after each operation. The installed app occupies 908 KB.

## Resource use

Measured on macOS 26.5.2 after fetching both providers:

| State | Physical footprint | Idle CPU |
|---|---:|---:|
| Previous Swift/AppKit build after using the panel | 25.7 MB | 0.0% |
| Current build, before the panel is opened | 12 MB | 0.0% |
| Current build, panel visible | 13 MB | 0.0% |
| Current build, after closing the panel | 12 MB | 0.0% |

The remaining memory is macOS infrastructure. A minimal process containing only
`NSApplication` and `NSStatusItem` measures about 12.4 MB on the same system. AppKit's
allocator zones, Objective-C metadata, Core Animation, and shared-framework writable
pages establish that floor. A sub-1 MB process cannot expose a supported, native menu-bar
item with the same UI.

Rust would still call AppKit and pay the same floor. Objective-C keeps the resident host
smaller because it uses AppKit directly without loading the Swift runtime. The Swift
helper remains useful for typed provider decoding because its memory disappears when it
exits.

Showing the panel costs a few hundred KB of dirty memory, mostly `MALLOC_SMALL` growth and
one CG image backing store that tracks the panel's height. Releasing the panel and calling
`malloc_zone_pressure_relief` returns all of it, so the host holds one process and one
status item for its whole life. Sampling the footprint once per second across an open and
close cycle shows 12 MB, then 13 MB while visible, then 12 MB again, at a single unchanging
pid.

## Refresh behavior

The app loads its last validated 8,480-byte snapshot at launch. A normal login launch
starts no fetch helper, touches no credential, and opens no network connection. A first
launch with no cache fetches once to seed it. The app performs no periodic usage polling
while hidden. It refreshes usage when the panel opens with data older than 60 seconds, or
when the user selects Refresh.

Claude outage alerts use a separate status-only helper every 30 minutes when alerts are
enabled. That helper does not access Keychain or provider usage APIs. Disabling alerts
removes the timer. Timers use a five-minute tolerance so macOS can coalesce wakeups.

This design trades short refresh-time process launches and fresh network connections for
the smallest persistent memory footprint.

## Authentication

AgentUsageBar reads credentials already owned by the provider CLIs:

| Provider | Credential source | Usage endpoint |
|---|---|---|
| Claude | Keychain item `Claude Code-credentials` | `api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json` | `chatgpt.com/backend-api/wham/usage` |

The app stores no credentials. Codex token refreshes remain in the helper's memory and do
not modify the CLI file.

The fetcher reads the Claude item by running `/usr/bin/security find-generic-password`,
which never raises a consent prompt. Claude Code writes that item with
`security add-generic-password -U` and passes neither `-T` nor `-A`, so every token refresh
installs a fresh ACL trusting only `/usr/bin/security`. An Always Allow grant issued to any
other binary therefore survives only until the next refresh, a few hours at most. Reading
through the one tool already on the trusted-application list sidesteps that entirely, and
leaves the app with no code that links `Security.framework`.

## Features

- Claude session, weekly, scoped, and monthly-budget usage
- Codex rate-limit windows, model meters, credit balances, and reported budgets
- User-supplied monthly limits when a provider reports spend without a limit
- Per-service Claude status tracking and outage notifications
- System, Dark, and Light appearance modes
- Global Command-U panel shortcut
- Start at login by default, with a saved opt-out
- Right-click Refresh and Quit menu

The panel uses one custom `NSView` with manual drawing and hit testing. It creates no
Auto Layout graph and no control hierarchy. Closing it releases the panel, event monitors,
view, and backing surfaces, then asks the allocator to return unused pages.

The host loads ServiceManagement only when the login setting changes, which means first
launch and explicit toggles. It registers the main app directly, because
`SMAppService.mainAppService` resolves through the main bundle and reports `NotFound` from a
bare helper in `Contents/Helpers`.

## Build

Requirements: macOS 14 or newer, Xcode command-line tools, and Apple silicon.

```bash
cd app
./make_signing_cert.sh  # once, for a stable local Keychain identity
./build.sh
```

The build runs fifteen deterministic protocol and cache tests, compiles size-optimized
arm64 binaries with full link-time optimization, strips local symbols, signs every helper
and the app, and verifies the nested signature. The result is
`app/build/AgentUsageBar.app`.

When the `AgentUsageBar Dev` identity exists, the build uses it automatically. Otherwise
it produces an ad-hoc build. Set `CODESIGN_IDENTITY` to use a Developer ID or another
explicit identity.

## Architecture

```text
AgentUsageBar (resident Objective-C/AppKit host)
  ├─ AgentUsageFetcher -- usage mode
  │    provider files + URLSession + typed Swift decoders
  │    └─ /usr/bin/security
  │         one bounded Keychain read, then exits
  └─ AgentUsageFetcher -- status-only mode
       status.claude.com + optional notification
```

The fetcher sends a bounded, versioned tab-separated protocol. The host rejects duplicate
providers, unknown enum values, out-of-order records, oversized output, truncated fields,
and invalid numeric ranges before replacing its snapshot.

Both providers use internal endpoints that can change. The protocol and provider decoders
surface unexpected values instead of silently treating new states as valid.
