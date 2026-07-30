# Codex Usage: Product and Usage Guide

English | [简体中文](product-and-usage.md)

Version: v1.5.0

System: macOS 14 or later

Architectures: Apple Silicon (`arm64`) and Intel (`x86_64`)

## Overview

Codex Usage is a native macOS menu bar utility for checking:

- remaining Codex usage;
- reset dates and countdowns;
- tasks that are running normally;
- tasks waiting for approval, a choice, input, an upload, or a reply.

The app has no main window or Dock icon. Completed-task counts are intentionally omitted.

## Menu Bar

The English interface looks similar to:

```text
Codex 90% · 4h 25m · ▶ 1 | ⏸ 0
```

| Item | Meaning |
|---|---|
| `Codex 90%` | Remaining percentage for the shortest usage window |
| `4h 25m` | Time until that window resets |
| `▶ 1` | Number of tasks running normally |
| `⏸ 0` | Number of tasks waiting for you |

Open the menu to see every returned usage window, exact reset times, the Codex plan, task titles, the latest successful update time, and app actions.

The app queries up to the 50 most recently updated Codex tasks. Each task category lists up to five titles in the menu; the menu bar count reflects all tasks recognized in that query.

## Task States

### `▶` Running

A task is normally counted as running when Codex is reasoning, producing output, calling tools, or continuing after you approved or supplied something.

### `⏸` Waiting for Action

A task is normally counted as waiting when:

- a privileged operation needs approval;
- Plan mode is waiting for a choice;
- a form or other manual input is required;
- the completed response explicitly asks you to provide information, choose, upload, confirm, or reply;
- the next step clearly depends on an action from you.

Codex runtime flags and pending tool calls take priority. For completed turns, the app can inspect the full final response to determine whether a reply is still required. Code samples, quotations, optional suggestions, negative statements, and already completed actions are excluded where possible.

Natural language is ambiguous, so occasional false positives or missed waiting states remain possible.

### Completed and Failed Tasks

Completed tasks are not shown. Completion markers are still recognized internally so a finished task is removed from `▶`.

If Codex explicitly reports a system error, the menu shows an `⚠ Errors` count. Failed tasks are not included in `▶` or `⏸`.

## Refresh Behavior

The app starts a local `codex app-server --stdio` subprocess, reuses your existing Codex sign-in, and keeps a persistent local connection. Usage and task state are refreshed every five seconds.

This is high-frequency polling, not a server push. A state change normally appears after the next refresh plus the time Codex needs to respond.

Choose **Refresh Now** or press `R` while the menu is open to refresh immediately. Concurrent refresh requests are prevented.

If a refresh fails after a successful result, the menu bar keeps the last result and the menu shows the error. Automatic reconnection attempts continue.

## Interface Language

Open the menu and select **Language**:

- **Follow System** uses Simplified Chinese when the first preferred macOS language is Chinese; otherwise it uses English.
- **Simplified Chinese** always uses the Chinese interface.
- **English** always uses the English interface.

The change is immediate. The selected option is stored locally in macOS preferences. Codex task titles are displayed as received and are not translated.

## Requirements and Download Choice

- macOS 14 or later;
- an Apple Silicon or 64-bit Intel Mac;
- a signed-in Codex desktop app, Codex included with the ChatGPT desktop app, or Codex CLI.

Download:

| Archive marker | Mac |
|---|---|
| `macOS-arm64` | Apple M-series chip |
| `macOS-x86_64` | Intel processor |

Run `uname -m` in Terminal if you are unsure. Choose `arm64` when it returns `arm64`, or `x86_64` when it returns `x86_64`.

The release archive uses the ASCII name `CodexQuotaMenu` to prevent GitHub from rewriting asset names. The extracted application is still named `Codex用量.app`.

## Install and Verify

1. Download the ZIP matching your Mac from the same GitHub Release.
2. Download the matching `.sha256` file.
3. Verify the archive.
4. Extract it and move `Codex用量.app` to Applications.

Apple Silicon:

```sh
shasum -a 256 -c CodexQuotaMenu-v1.5.0-macOS-arm64.zip.sha256
```

Intel:

```sh
shasum -a 256 -c CodexQuotaMenu-v1.5.0-macOS-x86_64.zip.sha256
```

An `OK` result confirms that the ZIP matches its checksum file. Download both files from the same official Release.

## First Launch

The project does not currently have an Apple Developer certificate. Builds use Hardened Runtime and an ad-hoc signature but are not notarized.

If macOS blocks the first launch:

1. Open Applications in Finder.
2. Right-click `Codex用量.app`.
3. Select **Open**.
4. Select **Open** again in the system prompt.

Do not disable macOS security features or run untrusted quarantine-removal commands.

## Start at Login

Open **System Settings → General → Login Items**, click **+**, and select `Codex用量.app` from Applications.

## Privacy and Security

The app processes:

- usage percentages, reset times, and plan type;
- recent task identifiers, titles, timestamps, and runtime states;
- local session-log paths returned by Codex;
- up to the last 512 KB of relevant session logs;
- the selected interface language.

Session-log fragments may contain task titles, tool-call metadata, and the current response. They are processed in memory and are not copied, uploaded, or stored in a project database. The app does not read or save account tokens, passwords, or API keys and has no advertising, analytics, or telemetry.

The language preference is the only setting persisted by this app. It contains no task content or identity information.

App Sandbox is not enabled because the app must launch a local Codex subprocess and read Codex session logs. The app does not request camera, microphone, contacts, calendar, location, photo-library, or Accessibility permissions.

See the [privacy notice](../PRIVACY.en.md) and [security policy](../SECURITY.en.md).

## Troubleshooting

### No window appears

This is a menu bar app. Look at the top-right area of the macOS menu bar; it has no normal window or Dock icon.

### The menu stays on “Loading…” or shows `Codex --`

- Confirm that Codex or the ChatGPT desktop app is installed and signed in.
- Open Codex and make sure it works normally.
- Choose **Refresh Now** or restart the utility.

### “Codex was not found”

The app checks common Codex application and CLI locations. Advanced users can set a trusted executable in the launch environment:

```sh
CODEX_CLI_PATH=/full/path/to/codex
```

Apps launched from Finder do not normally inherit temporary environment variables from a Terminal session.

### A running or waiting count looks wrong

Wait for the next five-second refresh or choose **Refresh Now**. Incomplete logs that have not changed for more than 30 minutes are not treated as running. Natural-language waiting detection may occasionally be incorrect.

## Quit and Uninstall

Choose **Quit** or press `Q` while the menu is open.

To uninstall:

1. Quit the app.
2. Remove it from Login Items.
3. Move `Codex用量.app` from Applications to Trash.

The app creates no database or cache directory. To also remove the saved language preference:

```sh
defaults delete com.local.codexquotamenu
```

Uninstalling this utility does not remove Codex, your Codex sign-in, or task history.

## Project and License

This independent community project is not affiliated with or endorsed by OpenAI and does not use official OpenAI or Codex trademarks in its icon.

Source code is available under the [MIT License](../LICENSE).
