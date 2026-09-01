# Codex Usage: Product and Usage Guide

English | [简体中文](product-and-usage.md)

Version: v1.6.2

System: macOS 14 or later

Architectures: Apple Silicon (`arm64`) and Intel (`x86_64`)

## Overview

Codex Usage is a native macOS menu bar utility for checking:

- remaining Codex usage;
- reset dates and countdowns;
- tasks that are currently active;
- the next-48-hour probability of a global bonus reset from Codex Reset Monitor.

The app has no main window or Dock icon. Completed-task counts are intentionally omitted.

The menu bar uses a text-only presentation with no extra icon before `Codex`, keeping the display compact and visually clean.

## Menu Bar

The English interface looks similar to:

```text
Codex 90% · 4h 25m · ↻30% · ▶ 1
```

| Item | Meaning |
|---|---|
| `Codex 90%` | Remaining percentage for the shortest usage window |
| `4h 25m` | Time until that window resets |
| `↻30%` | Primary probability of a global bonus reset in the next 24 hours |
| `▶ 1` | Number of tasks that are still active |

Open the menu to see every returned usage window, exact reset times, the Codex plan, task titles, the latest successful update time, and app actions.

The app queries up to the 50 most recently updated Codex tasks. Each task category lists up to five titles in the menu; the menu bar count reflects all tasks recognized in that query.

## Task States

### `▶` Active

A task is counted as active when Codex reports it as active, when the latest structured lifecycle event is `task_started`, or when lifecycle markers are outside the read window but recent activity remains in the log. Incomplete logs that receive no updates for more than 30 minutes are excluded.

The app no longer separates “running” from “waiting for user action,” and it does not inspect response text to infer whether you need to approve, choose, enter information, upload, or reply. This removes the false-positive-prone `⏸` classification.

### Completed and Failed Tasks

Completed tasks are not shown. Completion markers are still recognized internally so a finished task is removed from `▶`.

If Codex explicitly reports a system error, the menu shows an `⚠ Errors` count. Failed tasks are not included in `▶`.

## Refresh Behavior

The app starts a local `codex app-server --stdio` subprocess, reuses your existing Codex sign-in, and keeps a persistent local connection. Usage and task state are refreshed every five seconds.

This is high-frequency polling, not a server push. A state change normally appears after the next refresh plus the time Codex needs to respond.

Choose **Refresh Now** or press `R` while the menu is open to refresh immediately. Concurrent refresh requests are prevented.

If a refresh fails after a successful result, the menu bar keeps the last result and the menu shows the error. Automatic reconnection attempts continue.

Forecasts refresh independently every five minutes from `codexreset.org/api/monitor-summary`. Data is marked cached after 15 minutes and hidden after two hours; forecast failure cannot block personal quota or task refreshes.

These are public community forecasts, not an official reset schedule or guarantee.

## Daily Activation Times

Open **Activation Times…**, add the times you need each day, then choose **Sync to Codex**. The list is empty on first launch. The app copies a complete reconciliation prompt and opens a new Codex conversation; you still need to paste and send it once before Codex can create or correct the official automations.

The app manages only tasks whose name exactly follows `CodexQuotaMenu · HH:mm`; it does not adopt existing tasks without that prefix. If the time list is empty, the generated sync prompt cleans up only managed tasks with that prefix.

Choosing Sync alone never shows **Synced**. After you send the prompt, the window rechecks configuration through a local read-only reconciliation and shows **Synced** only when the saved settings and managed task configuration match exactly. A local reconciliation cannot prove that an individual background run succeeded. You need to sync again only after changing a time; quitting CodexQuotaMenu does not stop or remove official background automations already created. Successful scheduled runs are silent; Codex notifies according to the task notification policy when a run fails.

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

Use the following filenames to verify the official v1.6.2 release assets:

```sh
shasum -a 256 -c CodexQuotaMenu-v1.6.2-macOS-arm64.zip.sha256
```

Intel:

```sh
shasum -a 256 -c CodexQuotaMenu-v1.6.2-macOS-x86_64.zip.sha256
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

## iPhone Scriptable Lock-Screen Widget

1. Choose **Phone Widget → Enable Read-Only API** in the Mac menu.
2. Copy the widget address and access token separately. The full token is never displayed in the menu.
3. Import [`mobile/CodexQuotaWidget.js`](../mobile/CodexQuotaWidget.js) into Scriptable and follow the [mobile setup guide](../mobile/README.md).
4. Test in Scriptable, then add its accessory rectangular widget to the lock screen.

Plain HTTP is intended only for a trusted LAN or an existing encrypted Shadowrocket/VPN home tunnel; never port-forward it. Prefer a DHCP-reserved Mac LAN address because `.local` may not resolve through a tunnel. The script suggests the earliest next refresh after five minutes, but iOS decides the actual schedule.

## Privacy and Security

The app processes:

- usage percentages, reset times, and plan type;
- recent task identifiers, titles, timestamps, and runtime states;
- local session-log paths returned by Codex;
- up to the last 512 KB of relevant session logs;
- the selected interface language;
- public forecast values, status, and timestamps;
- whether the phone feed is enabled and its access token.

To reconcile daily activation times, the app read-only scans `~/.codex/automations/*/automation.toml` and extracts only the managed task name, status, and configuration fields needed for reconciliation. It does not write those files, read automation run conversations, or upload automation configuration. A local check can confirm matching configuration, but cannot prove that an individual background run succeeded.

Session-log fragments may contain task titles, tool-call metadata, and the current response. They are processed in memory and are not copied, uploaded, or stored in a project database. The app does not read or save Codex account tokens, passwords, or API keys and has no advertising, analytics, or telemetry.

The app sends GET requests only to the documented `codexreset.org` public forecast endpoint and sends it no personal quota, task, identity, session, or Codex credential data. `UserDefaults` stores language, the phone-feed toggle, and the non-personal forecast cache; macOS Keychain stores the 32-byte phone token. Phone JSON excludes task titles, paths, and conversations. Scriptable stores its address and token in Scriptable Keychain and writes only non-sensitive JSON to its file cache.

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

### The active-task count looks wrong

Wait for the next five-second refresh or choose **Refresh Now**. Incomplete logs that have not changed for more than 30 minutes are not treated as active.

## Quit and Uninstall

Choose **Quit** or press `Q` while the menu is open.

To uninstall:

1. Quit the app.
2. Remove it from Login Items.
3. Move `Codex用量.app` from Applications to Trash.

The app creates no user database or separate cache directory, but keeps public forecast cache and preferences in `UserDefaults` and the phone token in Keychain. To remove the preferences and forecast cache:

```sh
defaults delete com.local.codexquotamenu
```

To remove the phone token, delete Keychain service `com.local.codexquotamenu.widget` in Keychain Access. Scriptable's Keychain values and non-sensitive cache must be removed separately on the iPhone.

Uninstalling this utility does not remove Codex, your Codex sign-in, or task history.

## Support the Project

If this utility is useful to you, you can optionally support ongoing maintenance through [Afdian](https://afdian.com/a/520_00) or [Ko-fi](https://ko-fi.com/520_00). Donations do not affect downloads, features, updates, or issue reporting.

The donation links appear only in the project documentation and GitHub Sponsor button; the app itself does not load or connect to either platform. Each platform's own privacy policy and terms apply after you follow its link.

## Project and License

This independent community project is not affiliated with or endorsed by OpenAI and does not use official OpenAI or Codex trademarks in its icon.

Source code is available under the [MIT License](../LICENSE).
