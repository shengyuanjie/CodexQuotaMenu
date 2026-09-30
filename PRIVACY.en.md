# Privacy Notice

English | [简体中文](PRIVACY.md)

Last updated: September 29, 2026

## Scheduled Message Data

User-scheduled message text, target ID and title, model, reasoning effort, time and status are stored in `~/Library/Application Support/CodexQuotaMenu/ScheduledMessages/` (directory mode 700, records mode 600). LaunchAgents contain only the record ID. Records remain until removed in the window; cancel pending messages there before uninstalling.

At delivery, the chosen message is passed to the local Codex desktop session or CLI and may reach Codex services under Codex's own data-handling rules. Desktop snapshots may contain conversation and tool history; they are processed only in memory, capped at 128 MB per frame, and are not saved. Raw CLI output and the outgoing prompt use restricted temporary files removed afterwards; persisted results use fixed categories. Uncertain attempts are never automatically retried.

## Default Model Settings

Only **Save and Verify** in **Default Model…** updates the model and reasoning effort in local Codex user configuration. Catalog reads and configuration saves do not generate model responses or upload configuration to this project's servers.

The app reads backend configuration and managed new-chat defaults. If an override matches local `/etc/codex/requirements.toml`, modifying it requires macOS administrator authentication; the app never reads or stores the password. Only model and reasoning-effort fields in `[models.new_thread]` change. Other contents are preserved. Ambiguous formats, conflicting edits, and unidentified override sources are refused.

Before a system edit, a `requirements.toml.codexquotamenu-<random-id>.bak` file is created beside the original, containing its full contents with owner-only read/write permissions. This backup may contain other configuration and must not be uploaded to GitHub or shared publicly. Uninstalling does not restore Codex defaults or delete these backups. Existing chats and background activation models do not automatically change with global defaults.

Codex Usage Menu Bar is designed around local processing. The project operates no public service and includes no advertising, telemetry, or user analytics. A user may explicitly enable a Mac-local LAN service for the phone widget; it is off by default.

## Data Read Locally

The app starts `codex app-server --stdio` through a Codex executable already installed on the user's Mac and reads:

- Codex usage percentages, reset times, and plan type;
- recent task identifiers, titles, update times, and runtime states;
- local session-log paths returned by Codex;
- up to the last 512 KB of each relevant session log, used only to identify structured lifecycle events such as task starts, user messages, and task completions, plus whether the log has been active recently.

For ordinary daily reconciliation, the app reads and validates only exact-owned LaunchAgent plists such as `~/Library/LaunchAgents/com.local.codexquotamenu.activation.HHMM.plist` and checks their per-user loaded state through `launchctl`. During first migration, it locally reads `~/.codex/automations/*/automation.toml` to identify and safely migrate entries whose complete name exactly matches `CodexQuotaMenu · HH:mm`; it does not read their run conversations, and it does not modify other automations or prefix-sharing names. Legacy Codex automations must be paused in Codex itself. The app checks their local status and preserves their files; it does not infer scheduler cancellation from file removal.

Session-log fragments may include task titles, tool-call metadata, and text from the current response.
The app does not analyze response text or tool-call contents to infer whether the user needs to approve, choose, enter information, upload, or reply.

## Public Forecast Requests

Every five minutes, the app requests `GET https://willcodexreset.com/api/reset-radar`. This is an independent community source with no OpenAI affiliation or endorsement. The app reads at most a 64 KiB response prefix and extracts only the response code, `data.probability48h`, and `data.updatedAt`; it never retains or caches `events` text.

Requests contain only normal HTTP metadata, a JSON Accept header, and an app-version User-Agent. The app does not send personal Codex quota, plan, task, session, identity, or credential data to the site. Forecast failure cannot block local quota queries.

## Data Handling

- Local Codex session content and task details are processed only in device memory. Public forecast cache and user settings are stored locally as described below.
- The app does not create its own user database.
- The app does not copy or upload existing conversation history; explicitly scheduled messages are passed to Codex as described above.
- The app writes only its own user-level LaunchAgent plists when the user schedules a message or chooses **Apply to Codex**, and performs the narrowly scoped legacy migration. It does not read activation-run conversations or upload scheduler configuration. Legacy Codex automations must be paused in Codex itself. The app checks their local status and preserves their files; it does not infer scheduler cancellation from file removal.
- The app does not read or save Codex account tokens, passwords, or API keys.
- The app implements no telemetry, crash reporting, or user-data upload. Network behavior is limited to the documented `willcodexreset.com` public forecast GET, the user-enabled local read-only feed, and Codex's own normal connections.
- In-memory query results are released when the app exits.

The app stores locally:

- macOS `UserDefaults`: interface language, the phone-feed toggle, the non-personal v3 public forecast summary cache, the two quota summaries and reset times used to detect completion of the current reset cycle, and each activation entry's hour, minute, enabled state, and stable local ID. The forecast summary contains only probability, source update time, and local fetch time, never `events`; this state remains local and forecast data is hidden after two hours;
- macOS Keychain: the 32-byte random access token created when the phone feed is first enabled; while the feed is running, one copy remains only in app-process memory and disappears when the app exits;
- process memory: the latest personal quota, task summary, and generated phone JSON snapshot.

The phone token is never placed in `UserDefaults`, URLs, logs, or responses. Phone JSON contains only quota, reset dates, running-task count, and forecast summaries. Forecast fields are `probability48h`, `updatedAt`, `isCached`, `source`, and an optionally omitted `calibrationState`; it contains no task title, file path, conversation content, or `events`.

On iPhone, the Scriptable script stores its address and token in Scriptable Keychain. Its local file cache contains only the last successful non-sensitive JSON and receipt time, never the address or token. After two hours, stale quota and forecast percentages are hidden.

The Codex subprocess may connect to OpenAI as part of Codex's normal operation. This project does not control Codex's own data handling.

Local reconciliation can confirm only whether saved activation times, managed plist configuration, and per-user loaded state match; it cannot prove that an individual background run succeeded. The app's headless runner keeps activation silent. The latest summary per time and a separate diagnostic record for each run is stored in `~/Library/Logs/CodexQuotaMenu/Activation/`, containing timestamps, exit codes, error categories, usage percentages and before/after window deadlines only. Raw command output is captured in a restricted temporary directory and removed afterwards. Each run resolves the CLI again and checks structured turn completion, stable deadlines across two queries and nonzero quota usage. Unverified or transient failures are retried once after 15 seconds; authentication and quota errors are not retried immediately. If the existing window expires within ten minutes, the runner waits until five seconds after expiry; otherwise it records that the existing window remains active. Activation schedules are managed only in CodexQuotaMenu and do not appear in Codex's scheduled-task list. Quitting this app does not affect existing LaunchAgents.

## Permissions and Sandbox

App Sandbox is not enabled because the core features require the app to:

- start a local Codex subprocess;
- read local session logs at paths returned by Codex.
- read and write its own user-level LaunchAgents.

The app does not request camera, microphone, contacts, calendar, location, photo-library, or Accessibility access. macOS may show a Local Network prompt only after the user enables the phone feed.

## User Control

Quit the app to stop all reads and the local service, or disable the phone feed independently. If a token may have leaked, regenerate it in the menu; the old token becomes invalid immediately.

Before completely uninstalling, if the app is still present, remove every time in **Activation Times…**, choose **Apply to Codex**, and confirm **Not Configured** before deleting the app. If the app has already been deleted, handle only LaunchAgents whose filename and plist `Label` both exactly match `com.local.codexquotamenu.activation.HHMM` for a valid 24-hour time. Inspect each item, run `launchctl bootout gui/$(id -u)/<exact-label>` for that exact label, and remove only its corresponding exact plist; never use a prefix wildcard for deletion. The product guide provides the complete per-item commands.

To remove the language, toggle, activation entries, public forecast cache, and reset-detection state from `UserDefaults`, run:

```sh
defaults delete com.local.codexquotamenu
```

Deleting the app does not automatically delete its Keychain item. Use Keychain Access to remove service `com.local.codexquotamenu.widget` if desired. Scriptable Keychain values and its non-sensitive cache must be removed separately on the iPhone.

## Project Relationship

This is an independent community project. It is not affiliated with or endorsed by OpenAI.
