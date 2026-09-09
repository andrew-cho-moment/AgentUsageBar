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

The app loads its last validated 8,480-byte snapshot at launch and renders it without a
fetch. A first launch with no cache fetches once to seed it, and a launch whose cached
snapshot is already older than the poll interval fetches as soon as the poll arms, which
is the usual case after the machine has been off.

Usage and Claude service status both refresh when the panel opens with data older than 60
seconds, when the user selects Refresh, and on a background poll every 5 minutes. A run
that wants both halves fetches them in one helper process, which overlaps the two network
calls; changing which services are tracked runs a status-only helper that touches no
credential and no provider usage API.

The poll is one non-strict `dispatch_walltime` timer with 60 seconds of leeway, so the
kernel folds its wake into one it was already making, and it never wakes a sleeping
machine. Its deadline is wall clock, so a machine that slept past the deadline polls on
wake rather than drifting by the length of the sleep. The cadence counts from the attempt
rather than the result, which keeps an unreachable provider on the same 5-minute
spacing instead of a retry loop, and a failed poll leaves the last numbers in the menu bar
rather than replacing them with an error the user did not ask for. When a meter reports a
reset within the interval, the poll moves to just past that boundary so the percentage
drops when the window actually rolls over.

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

A provider whose CLI this machine has never had gets no mention anywhere in the app: no
menu-bar segment, no panel row, no sign-in hint, and for Claude no service-status section
and no service-tracking settings. The fetcher decides that from the state each CLI writes
on its first run, `~/.claude.json` or `~/.claude` for Claude Code and `~/.codex` for Codex,
rather than from the binary, because an app launched at login inherits no shell `PATH` and
would read a machine that runs an agent daily as having none. When no provider is signed
in, the panel offers a `claude login` or `codex login` hint for each CLI that is installed
and omits the one that is not, which is the distinction the `not_installed` provider state
carries through the protocol.

Settings holds a folder for each provider, so a machine that keeps its agent state
somewhere other than the default is one setting away from working. Each provider reads
the folder from Settings first, then `CLAUDE_CONFIG_DIR` or `CODEX_HOME` when a shell
launched the app, then the location its CLI installs to. The setting comes first because
an app launched at login inherits no shell environment and cannot see either variable.

Every fetch reports the folder it read and which of those three named it, so the Settings
row shows the folder in use rather than the setting's own value, and offers Clear only for
a folder the setting named. A chosen folder that is missing reports itself as a provider
error rather than reading as an absent CLI, whether a setting or a variable chose it:
someone picked that folder and can fix it, where silence would look like a broken app.

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
- Per-service Claude status tracking
- Only the providers installed on the machine, with the rest silent
- A configurable folder per provider, defaulting to what each CLI installs to
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

## Install

Requirements: macOS 14 or newer, Xcode command-line tools, and Apple silicon.

```bash
./setup.sh
```

That creates the local signing identity if it is missing, builds, replaces any copy in
`/Applications`, and launches the app. Re-running it is the update path: settings live in
the `com.andrewcho.agentusagebar` defaults domain rather than in the bundle, so replacing
the bundle keeps them.

Each run also clears state that outlives the build which created it. Every test bundle in
this project's history took a suffixed bundle id, and macOS made each one a shader cache
and a preferences domain that nothing deletes when the build goes away. The sweep removes
those, along with defaults keys the current app no longer reads and any `.DS_Store` in the
tree, while leaving the live domain and the snapshot cache alone. `./setup.sh --clean`
runs that sweep by itself.

## Build

To build without installing:

```bash
cd app
./make_signing_cert.sh  # once, for a stable local Keychain identity
./build.sh
```

The build runs seventy-six deterministic protocol, cache and response-decoding tests,
compiles size-optimized arm64 binaries with full link-time optimization, strips local
symbols, signs every helper and the app, and verifies the nested signature. The result
is `app/build/AgentUsageBar.app`.

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
       status.claude.com
```

The fetcher sends a bounded, versioned tab-separated protocol. The host rejects duplicate
providers, unknown enum values, out-of-order records, oversized output, truncated fields,
and invalid numeric ranges before replacing its snapshot.

Both providers use internal endpoints that can change. The protocol and provider decoders
surface unexpected values instead of silently treating new states as valid, and each part
of a response is decoded in isolation so a surprise in one cannot cost the others: a new
`spend.severity` string reports itself and leaves every rate-limit window standing.
