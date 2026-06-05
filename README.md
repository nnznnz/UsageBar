# UsageBar

A menu-bar app for macOS that shows how much of your AI-coding subscriptions
you've burned through — Claude, Codex/ChatGPT, GitHub Copilot, Cursor — in one
glance, **built to run only on your own Mac with nothing to trust but the code
in this folder.**

It's a from-scratch, single-user reimplementation of the idea behind
[OpenUsage](https://github.com/robinebers/openusage) (see [CREDITS.md](CREDITS.md)).
The point of rebuilding it: these tools read the credentials that authorize your
AI accounts. That's exactly the kind of access you don't want to hand to a
third-party app you can't fully audit. This one you can read end to end in an
afternoon, and it has **zero third-party dependencies**.

---

## The security model (read this first)

This is the whole reason UsageBar exists, so it's not an afterthought:

1. **Zero third-party dependencies.** Everything is built on Apple's own system
   frameworks — AppKit (UI), Foundation/URLSession (HTTP), Security (Keychain),
   CryptoKit (one hash). There is no npm, no Cargo, no pip, no supply chain. The
   only thing to audit is the ~1,400 lines of Swift in `Sources/`. If a
   `Package.resolved` ever appears, something pulled in a dependency — treat that
   as a red flag.

2. **Network egress is allowlisted (exact-host match).** Every outbound request
   is checked against a hard allowlist that is the *union of the hosts each
   enabled provider declares* — and nothing else. Matching is **exact**: allowing
   `api.github.com` does NOT allow `evil.api.github.com` (a unit test enforces
   this). A request to any other host is blocked before a byte leaves the machine
   (`Net/HTTPClient.swift`). Today the entire list is: `api.anthropic.com`,
   `platform.claude.com`, `chatgpt.com`, `auth.openai.com`, `api.github.com`,
   `api2.cursor.sh` — and only the ones for providers you've turned on. Disable a
   provider and its hosts aren't even reachable.

3. **No redirects, HTTPS only.** A 3xx is never followed (a classic way to bounce
   an authenticated request to an attacker), and plain `http://` is refused. TLS
   is validated by the OS trust store.

4. **No telemetry, no analytics, no auto-update, no "phone home."** There is no
   code that contacts any server other than the provider APIs above. Nothing is
   uploaded, ever.

5. **No local server.** The upstream tool exposes a `localhost:6736` HTTP API so
   other apps can read your usage. That's a real attack surface (any local
   process — or a malicious web page via DNS rebinding — could read it). UsageBar
   has no server. It only talks outward, to allowlisted hosts.

6. **Read-only credentials by default.** UsageBar *reads* the tokens that Claude
   Code, the Codex CLI, the GitHub CLI, and Cursor already store on your Mac. It
   does **not** write them. The single exception is opt-in token refresh (off by
   default — see [Token refresh](#token-refresh-opt-in)).

7. **Secrets never get logged.** Logging goes to stderr only and runs through a
   redactor that scrubs anything token-shaped (`Core/Log.swift`).

8. **macOS guards the keychain for you.** The first time UsageBar reads, say,
   Claude's keychain item, macOS prompts: *"UsageBar wants to use the credentials
   stored in 'Claude Code-credentials'."* Click **Always Allow** once. That
   prompt is the OS enforcing the boundary — and it's why a tool *you* built and
   authorized for *this specific binary* is safer than a third-party app.

---

## Build & run

You need the Xcode Command Line Tools (`xcode-select --install` if `swift`
isn't found). macOS 13 (Ventura) or newer.

```bash
./build.sh            # compiles a release binary, wraps it as UsageBar.app
open UsageBar.app     # launches into the menu bar (no Dock icon, no window)
```

First launch writes a starter config to `~/.config/usagebar/config.json` with
**Claude enabled** and the rest off.

Start it automatically at login (optional):

```bash
scripts/install-login-item.sh            # install + start now
scripts/install-login-item.sh --remove   # undo
```

Quick dev run without bundling: `swift run`.

### Tests & CI

```bash
swift test     # unit tests for the security-critical logic
```

The suite covers the egress allowlist (exact-host matching, subdomain rejection),
secret redaction across real token shapes, config fail-closed behavior, the
Cursor SQLite URI escaping, and the gh `hosts.yml` multi-host token parsing. A
[GitHub Actions workflow](.github/workflows/ci.yml) runs `swift build` + `swift
test` on a macOS runner on every push and fails the build if any third-party
dependency ever sneaks in (a `Package.resolved` appearing).

---

## What you'll see

The menu-bar stays out of your way: just the icon (`📊`), no number. It turns
into a red alert (`⚠`) only when an enabled provider maxes out a window (100%) —
or every enabled provider errors — and an orange alert if your config can't be
read. Click it for the breakdown — each provider's rolling windows as little bars:

```
Claude — Max 20x
Session          ████████░░░░  64%   · 2h 10m
Weekly           ██████░░░░░░  48%   · 4d 3h
Opus (weekly)    ██░░░░░░░░░░  18%   · 4d 3h
─────────────
Codex — Plus
Session          ███░░░░░░░░░  22%   · 3h
Weekly           █████░░░░░░░  41%   · 5d
─────────────
Updated just now
Refresh now
Open config…
Quit UsageBar
```

---

## Configuration

`~/.config/usagebar/config.json` (see [`config.example.json`](config.example.json)):

```json
{
  "refreshMinutes": 15,
  "providers": {
    "claude":  { "enabled": true,  "allowTokenRefresh": false },
    "codex":   { "enabled": false, "allowTokenRefresh": false },
    "copilot": { "enabled": false },
    "cursor":  { "enabled": false }
  }
}
```

- `refreshMinutes` — auto-refresh interval (clamped to 5–240; under 5 risks
  tripping provider rate limits). The menu also refreshes when you open it if the
  data is older than a minute.
- `enabled` — turn a provider on/off. Changes apply on the next refresh; you
  don't have to restart.

Edit it from the menu (**Open config…**) — it reveals the file in Finder.

**Fails closed.** If `config.json` exists but can't be parsed (a stray comma, a
typo), UsageBar does **not** fall back to defaults — it disables *every* provider
and shows a ⚠ warning in the menu bar and menu, so a JSON mistake can never
silently re-enable a provider you turned off. A missing file (first run) still
gets the Claude-on default.

---

## Providers & where they read credentials

Everything below is read locally; nothing is asked of you to paste in.

| Provider | Credential source (read-only) | Usage endpoint |
|---|---|---|
| **Claude** | Keychain `Claude Code-credentials`, then `~/.claude/.credentials.json` | `api.anthropic.com/api/oauth/usage` |
| **Codex** | `$CODEX_HOME/auth.json` → `~/.config/codex/auth.json` → `~/.codex/auth.json` → Keychain `Codex Auth` | `chatgpt.com/backend-api/wham/usage` |
| **Copilot** | `~/.config/gh/hosts.yml`, then Keychain `gh:github.com` (the `gh` CLI) | `api.github.com/copilot_internal/user` |
| **Cursor** | `~/Library/Application Support/Cursor/.../state.vscdb` (via system `sqlite3`), then Keychain `cursor-access-token` | `api2.cursor.sh/.../GetCurrentPeriodUsage` |

If a provider isn't set up on your machine, UsageBar shows a quiet "not logged
in" line rather than an error. Get logged in the normal way (`claude`, `codex`,
`gh auth login`, or just signing into Cursor) and it'll pick the token up.

### Token refresh (opt-in)

OAuth access tokens are short-lived. Two stances:

- **Default (`allowTokenRefresh: false`)** — fully read-only. UsageBar never
  touches your tokens. If a stored token is expired, it just shows the last known
  usage and a gentle "open the app to refresh" note. For a heavy Claude/Codex
  user this is almost always fine, because the CLI keeps the token fresh as you
  work.
- **Opt-in (`allowTokenRefresh: true`)** — when a token is expired, UsageBar
  refreshes it *and writes the new token back to the same place the CLI keeps it*
  (so the CLI stays logged in). This keeps usage live even after idle periods.
  It's off by default because it's the one time UsageBar writes a credential.
  (Cursor is **always** read-only regardless of this flag — writing its live
  SQLite store from outside is too risky.)

---

## Adding another provider

Each provider is one self-contained file in `Sources/UsageBar/Providers/`
implementing the `Provider` protocol (`id`, `displayName`, `allowedHosts`,
`fetch`). Copy `CopilotProvider.swift` (the simplest) as a template, declare the
hosts it needs in `allowedHosts` (that's what widens the egress allowlist — and
it's visible right there), and add an instance to the `providers` array in
`App/AppController.swift`. That's it.

OpenUsage documents ~17 providers (Gemini/Antigravity, Grok, Amp, Factory, Kimi,
etc.) if you want to port more — see their `docs/providers/`.

---

## Project layout

```
Sources/UsageBar/
  main.swift              app entry (accessory/menu-bar policy)
  App/AppController.swift menu-bar item, menu assembly, refresh scheduler
  UI/MenuRenderer.swift    snapshot → menu items (unicode progress bars)
  Core/                    Models, Provider protocol, Config, JSON, Util, Log
  Net/HTTPClient.swift     allowlisted, no-redirect, HTTPS-only HTTP
  Security/Keychain.swift  Security.framework generic-password read (+opt-in write)
  Storage/                 Files (creds files), SQLiteReader (Cursor, via system sqlite3)
  Providers/               Claude, Codex, Copilot, Cursor
```

---

## Troubleshooting

- **Keychain prompt keeps reappearing after rebuilding** — `build.sh` ad-hoc
  signs the app; rebuilding changes its code identity so macOS re-asks once.
  Click Always Allow again. (To make it stable across rebuilds, sign with a
  self-signed certificate of your own and swap `-` for its name in `build.sh`.)
- **A provider says "not logged in"** — log in via that tool's normal CLI/app on
  this same Mac and user account.
- **Want to see what it's doing** — run `swift run` from a terminal and watch
  stderr (tokens are redacted). You'll see the active allowlist and any blocked
  egress attempts logged loudly.
- **`swift` not found** — `xcode-select --install`.

See [CREDITS.md](CREDITS.md) for provenance and attribution.
