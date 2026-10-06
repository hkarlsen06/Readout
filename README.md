# UsageBar

A tiny macOS menu bar app that shows how much of your **Claude Code** and **Codex** usage limits you have left.

```
95/89 99
```

Orange is Claude Code (5-hour / weekly % left), blue is Codex. When a Codex limit runs out and you have credits, the blue number switches to your credit balance (`62.5k cr`). Click for per-window bars, reset countdowns, plan, and credits.

## Install

Download `UsageBar.zip` from the [latest release](https://github.com/hkarlsen06/UsageBar/releases/latest), unzip, move `UsageBar.app` to `/Applications`, and open it. Turn on **Launch at Login** from its menu.

UsageBar updates itself from GitHub Releases (checked at launch and every 6 hours; updates are only installed if signed with the author's Developer ID).

Requires macOS 13+ and that you're logged in to the `claude` and/or `codex` CLIs.

## How it works

- **Claude Code:** reads the OAuth token Claude Code stores in your Keychain (`Claude Code-credentials`) and calls `api.anthropic.com/api/oauth/usage`.
- **Codex:** reads `~/.codex/auth.json` and calls `chatgpt.com/backend-api/wham/usage`.

Tokens never leave your machine except to those endpoints. It never refreshes tokens itself — the CLIs do that — so if a login expires, open the CLI once. These are undocumented endpoints and may change.

## Build

```sh
./build.sh            # dev build, signed with Developer ID (SIGN_ID=- for ad-hoc)
./release.sh 1.2.3    # build, notarize, staple, tag, and publish a GitHub release
```
