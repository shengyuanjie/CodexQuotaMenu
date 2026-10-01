# Codex Usage: Product and Usage Guide

English | [简体中文](product-and-usage.md)

Version: v1.8.0

## Scheduled Messages

Open **Scheduled Message…**, choose an existing chat, model and supported reasoning effort, enter a message, and schedule one delivery. The time defaults to now; buttons adjust it by ±1 minute, ±10 minutes, ±1 hour or ±1 day. Choose a future time before scheduling. The editor supports Command+V and other standard editing shortcuts.

Use **Add files…** to select multiple files or photos, and **Remove attachment** to remove the selected entry. Attachment-only messages use “Please review the attachments.” Up to 20 attachments are allowed, with a 25 MB per-file and 100 MB total limit; folders and symbolic links are rejected. **Schedule** saves private copies in this message's own directory, so moving or deleting originals does not affect delivery. Photos use native image input; HEIC, TIFF and other supported ImageIO formats are converted to JPEG copies. Other files are referenced by local path for the target chat to read, subject to that chat's filesystem permissions. Copies are checked for integrity before delivery; missing or changed attachments fail the whole message. Copies remain with the record and are deleted when that record is removed.

Chats bind directly to IDs, including duplicate titles. Desktop-owned chats use the existing session and wait for an active turn to finish. Only CLI delivery directly checks working-directory permissions. `sent` requires verification of the accepted turn's completion; uncertain attempts are never automatically retried. Inspect failure details or cancel a message before delivery starts.

Each message uses a separate macOS LaunchAgent, not a Codex automation. Agents remain scheduled after the menu app quits, with missed-trigger delivery limited to 24 hours after the planned time. Desktop delivery depends on the installed Codex session interface. CLI execution and Codex's own project work can still require folder permissions.

## Default Model and Reasoning Effort

1. Open **Default Model…** from the Codex menu-bar menu.
2. Wait for the current defaults and live model catalog, then choose a model and one of its supported reasoning efforts.
3. Click **Save and Verify**. Editing a local system override may require macOS administrator authentication; the app does not receive your password.
4. After backend verification succeeds, new chats can use the new defaults. If the desktop app still shows cached values, restart Codex after running tasks finish.

Existing chats and the dedicated activation model remain unchanged. Available models depend on the signed-in account. Active profiles, unidentified managed-policy sources, or unsupported system-file formats are refused with an explanation. A failed save may leave partial updates; use **Refresh** to inspect actual values before retrying.

System edits affect only the model and reasoning effort in `/etc/codex/requirements.toml` under `[models.new_thread]`. A permission-restricted original-file backup is created beside it; do not share this backup publicly. See the [privacy notice](../PRIVACY.en.md).

System: macOS 14 or later

Architectures: Apple Silicon (`arm64`) and Intel (`x86_64`)

## Overview

Codex Usage is a native macOS menu bar utility for checking:

- remaining Codex usage;
- reset dates and countdowns;
- tasks that are currently active;
- the next-48-hour probability of a global bonus reset from the independent community source `willcodexreset.com`.

The app has no main window or Dock icon. Completed-task counts are intentionally omitted.

The menu bar uses a text-only presentation with no extra icon before `Codex`, keeping the display compact and visually clean.

## Menu Bar

The English interface looks similar to:

```text
Codex  5h90% left4h  W62% left2d  ▶1
```

| Item | Meaning |
|---|---|
| `5h90% left4h` | Remaining percentage and reset countdown for the five-hour window |
| `W62% left2d` | Remaining percentage and reset countdown for the weekly window |
| `▶1` | Number of tasks that are still active |

The title never shows a forecast percentage: at 50% or higher while encouragement is active it becomes `Codex  Go go go~ Pedal harder~  ▶1`; otherwise it shows quota details. Open the menu to see the `↻48h 82%` forecast, every returned usage window, exact reset times, the Codex plan, task titles, the latest successful update time, and app actions.

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

Forecasts refresh independently every five minutes from `https://willcodexreset.com/api/reset-radar`. The app reads at most the first 64 KiB of each response, extracts only the response code, 48-hour probability, and source update time, and never retains or caches `events` text. Forecast failure cannot block personal quota or task refreshes.

The displayed update time is `data.updatedAt`, meaning when the community source updated its own forecast. The local fetch time is stored separately and determines freshness: data is marked cached after 15 minutes and hidden after two hours. The compact summary uses the v3 cache key `globalReset.willCodexResetForecast.v3`.

When a low-probability cycle first reaches or exceeds 50%, the menu shows its encouragement message. It does not start another cycle while the probability stays high; after a completed reset it remains dismissed until the probability drops below 50% and crosses the threshold again.

`willcodexreset.com` is an independent community service with no affiliation with or endorsement by OpenAI. Its forecast is not an official reset schedule or guarantee.

## Daily Activation Times

Open **Activation Times…**, add the times you need each day, then choose **Apply to Codex**. The list is empty on first launch. The app directly creates or updates matching user-level LaunchAgents, with no copying, pasting, or send confirmation. Each enabled time invokes the official `codex exec --ephemeral` CLI for one activation; schedules are managed only in CodexQuotaMenu and do not appear in Codex's scheduled-task list or persist as recent Codex task conversations.

The app manages only LaunchAgent files and labels that exactly match `com.local.codexquotamenu.activation.HHMM` under `~/Library/LaunchAgents/`. Prefix-sharing files are not owned and remain untouched. If the time list is empty, **Apply to Codex** removes only the app's own LaunchAgents.

The app first stages and validates the complete target configuration, then replaces the managed LaunchAgents and attempts to restore this run's changes if synchronization fails. The window checks plist contents and actual `launchctl` loaded state automatically and shows **Synced** only when both match the saved settings. Manual refresh is hidden during normal operation; **Retry Check** appears only when status cannot be read. A local reconciliation cannot prove that an individual background run succeeded. You need to apply again only after changing a time; quitting CodexQuotaMenu does not stop or remove background LaunchAgents already created. The app's headless runner keeps activation silent. The latest summary per time and a separate diagnostic record for each run is stored in `~/Library/Logs/CodexQuotaMenu/Activation/`, containing timestamps, exit codes, error categories, usage percentages and before/after window deadlines only. Raw command output is captured in a restricted temporary directory and removed afterwards. Each run resolves the CLI again and checks structured turn completion, stable deadlines across two queries and nonzero quota usage. Unverified or transient failures are retried once after 15 seconds; authentication and quota errors are not retried immediately. If the existing window expires within ten minutes, the runner waits until five seconds after expiry; otherwise it records that the existing window remains active. After sleep, macOS may coalesce a missed calendar trigger into one catch-up run; the app does not perform additional catch-up runs. Legacy Codex automations must be paused in Codex itself. The app checks their local status and preserves their files; it does not infer scheduler cancellation from file removal.

Local status checks are read-only. The app changes its exact-owned LaunchAgents, and performs the narrowly scoped legacy migration, only when you choose **Apply to Codex**. Legacy Codex automations must be paused in Codex itself. The app checks their local status and preserves their files; it does not infer scheduler cancellation from file removal.

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

Use the following filenames to verify the official v1.7.0 release assets:

```sh
shasum -a 256 -c CodexQuotaMenu-v1.7.0-macOS-arm64.zip.sha256
```

Intel:

```sh
shasum -a 256 -c CodexQuotaMenu-v1.7.0-macOS-x86_64.zip.sha256
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
- public forecast probability, source update time, and local fetch time;
- whether the phone feed is enabled and its access token.

For ordinary synchronization and reconciliation, the app reads only exact-owned files such as `~/Library/LaunchAgents/com.local.codexquotamenu.activation.HHMM.plist` and checks their per-user service state through `launchctl`. During first migration, it locally reads `~/.codex/automations/*/automation.toml` to identify and safely migrate entries with the exact complete name `CodexQuotaMenu · HH:mm`; it does not read their run conversations or modify other automations. A local check can confirm matching plist and loaded state, but cannot prove that an individual background run succeeded. Legacy Codex automations must be paused in Codex itself. The app checks their local status and preserves their files; it does not infer scheduler cancellation from file removal.

Session-log fragments may contain task titles, tool-call metadata, and the current response. They are processed in memory and are not copied, uploaded, or stored in a project database. The app does not read or save Codex account tokens, passwords, or API keys and has no advertising, analytics, or telemetry.

The app sends GET requests only to the documented `https://willcodexreset.com/api/reset-radar` public forecast endpoint and sends it no personal quota, task, identity, session, or Codex credential data. It reads at most a 64 KiB response prefix and never retains event text. `UserDefaults` stores language, the phone-feed toggle, the non-personal v3 forecast summary containing only probability and timestamps, and each activation entry's hour, minute, enabled state, and stable local ID; macOS Keychain stores the 32-byte phone token. Phone JSON excludes task titles, paths, and conversations. Scriptable stores its address and token in Scriptable Keychain and writes only non-sensitive JSON to its file cache.

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

1. While the app is still installed, open **Activation Times…**, remove every time, choose **Apply to Codex**, and confirm **Not Configured**. This unloads and removes the app's exact-owned LaunchAgents.
2. Quit the app.
3. Remove it from Login Items.
4. Move `Codex用量.app` from Applications to Trash.

If the app has already been deleted, first list possible files without changing them:

```sh
find "$HOME/Library/LaunchAgents" -maxdepth 1 -type f \
  -name 'com.local.codexquotamenu.activation.*.plist' -print
```

Handle only items whose filename exactly matches `com.local.codexquotamenu.activation.HHMM.plist`, where `HH` is `00`–`23` and `MM` is `00`–`59`, and whose plist `Label` exactly equals the filename without `.plist`. For each confirmed item, replace `0630` below with that four-digit time, inspect the printed label, then unload and remove only that item. If `bootout` says the service is not loaded, the confirmed exact plist can still be removed.

```sh
label='com.local.codexquotamenu.activation.0630'
plist="$HOME/Library/LaunchAgents/$label.plist"
plutil -extract Label raw -o - "$plist"
launchctl bootout "gui/$(id -u)/$label"
rm -- "$plist"
```

Never use a wildcard such as `com.local.codexquotamenu.activation.*` for `bootout` or deletion. Prefix-sharing LaunchAgents are not owned by this app.

The app creates no user database or separate cache directory, but keeps public forecast cache and preferences, including activation entries, in `UserDefaults` and the phone token in Keychain. To remove the preferences and forecast cache:

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
