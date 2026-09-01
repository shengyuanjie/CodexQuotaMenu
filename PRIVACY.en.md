# Privacy Notice

English | [简体中文](PRIVACY.md)

Last updated: August 13, 2026

Codex Usage Menu Bar is designed around local processing. The project operates no public service and includes no advertising, telemetry, or user analytics. A user may explicitly enable a Mac-local LAN service for the phone widget; it is off by default.

## Data Read Locally

The app starts `codex app-server --stdio` through a Codex executable already installed on the user's Mac and reads:

- Codex usage percentages, reset times, and plan type;
- recent task identifiers, titles, update times, and runtime states;
- local session-log paths returned by Codex;
- up to the last 512 KB of each relevant session log, used only to identify structured lifecycle events such as task starts, user messages, and task completions, plus whether the log has been active recently.

To reconcile daily activation times, the app read-only scans `~/.codex/automations/*/automation.toml` and extracts only the managed task name, status, and configuration fields needed for reconciliation. Managed task names follow `CodexQuotaMenu · HH:mm`; the app does not adopt existing tasks without that prefix.

Session-log fragments may include task titles, tool-call metadata, and text from the current response.
The app does not analyze response text or tool-call contents to infer whether the user needs to approve, choose, enter information, upload, or reply.

## Public Forecast Requests

Every five minutes, the app requests `GET https://codexreset.org/api/monitor-summary` and reads only its next-48-hour probability.

Requests contain only normal HTTP metadata, a JSON Accept header, and an app-version User-Agent. The app does not send personal Codex quota, plan, task, session, identity, or credential data to the site. Forecast failure cannot block local quota queries.

## Data Handling

- Local Codex session content and task details are processed only in device memory. Public forecast cache and user settings are stored locally as described below.
- The app does not create its own user database.
- The app does not write, copy, or upload Codex session content.
- The app does not write `~/.codex/automations/*/automation.toml`, read automation run conversations, or upload automation configuration.
- The app does not read or save Codex account tokens, passwords, or API keys.
- The app implements no telemetry, crash reporting, or user-data upload. Network behavior is limited to the documented `codexreset.org` public forecast GET, the user-enabled local read-only feed, and Codex's own normal connections.
- In-memory query results are released when the app exits.

The app stores locally:

- macOS `UserDefaults`: interface language, the phone-feed toggle, the public forecast cache, and the two quota summaries and reset times used to detect completion of the current reset cycle. This state remains local; forecast data is hidden after two hours;
- macOS Keychain: the 32-byte random access token created when the phone feed is first enabled;
- process memory: the latest personal quota, task summary, and generated phone JSON snapshot.

The phone token is never placed in `UserDefaults`, URLs, logs, or responses. Phone JSON contains only quota, reset dates, running-task count, and forecast summaries; it contains no task title, file path, or conversation content.

On iPhone, the Scriptable script stores its address and token in Scriptable Keychain. Its local file cache contains only the last successful non-sensitive JSON and receipt time, never the address or token. After two hours, stale quota and forecast percentages are hidden.

The Codex subprocess may connect to OpenAI as part of Codex's normal operation. This project does not control Codex's own data handling.

Local reconciliation can confirm only whether saved activation times and managed task configuration match; it cannot prove that an individual background run succeeded. Successful created automations are silent, and Codex notifies according to the task notification policy when a run fails. Quitting this app does not affect official background automations.

## Permissions and Sandbox

App Sandbox is not enabled because the core features require the app to:

- start a local Codex subprocess;
- read local session logs at paths returned by Codex.

The app does not request camera, microphone, contacts, calendar, location, photo-library, or Accessibility access. macOS may show a Local Network prompt only after the user enables the phone feed.

## User Control

Quit the app to stop all reads and the local service, or disable the phone feed independently. If a token may have leaked, regenerate it in the menu; the old token becomes invalid immediately.

To uninstall, remove `Codex用量.app`. To remove the language, toggle, public forecast cache, and reset-detection state from `UserDefaults`, run:

```sh
defaults delete com.local.codexquotamenu
```

Deleting the app does not automatically delete its Keychain item. Use Keychain Access to remove service `com.local.codexquotamenu.widget` if desired. Scriptable Keychain values and its non-sensitive cache must be removed separately on the iPhone.

## Project Relationship

This is an independent community project. It is not affiliated with or endorsed by OpenAI.
