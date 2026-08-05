# Privacy Notice

English | [简体中文](PRIVACY.md)

Last updated: August 5, 2026

Codex Usage Menu Bar is designed around local processing. The project operates no server and includes no advertising, telemetry, or user analytics.

## Data Read Locally

The app starts `codex app-server --stdio` through a Codex executable already installed on the user's Mac and reads:

- Codex usage percentages, reset times, and plan type;
- recent task identifiers, titles, update times, and runtime states;
- local session-log paths returned by Codex;
- up to the last 512 KB of each relevant session log, used only to identify the latest user message, completion markers, and whether the task log has been active recently.

Session-log fragments may include task titles, tool-call metadata, and text from the current response.
The app does not analyze response text or tool-call contents to infer whether the user needs to approve, choose, enter information, upload, or reply.

## Data Handling

- The data above is processed only in device memory.
- The app does not create its own user database.
- The app does not write, copy, or upload Codex session content.
- The app does not read or save Codex account tokens, passwords, or API keys.
- The app does not implement telemetry, crash reporting, or network uploads.
- In-memory query results are released when the app exits.

The app stores the interface-language preference in macOS `UserDefaults`. Its only possible values are Follow System, Simplified Chinese, and English. This preference contains no task content, account information, or device identifier.

The Codex subprocess may connect to OpenAI as part of Codex's normal operation. This project does not control Codex's own data handling.

## Permissions and Sandbox

App Sandbox is not enabled because the core features require the app to:

- start a local Codex subprocess;
- read local session logs at paths returned by Codex.

The app does not request access to the camera, microphone, contacts, calendar, location, photos, or Accessibility.

## User Control

Quit the app to stop all reads. To uninstall, remove `Codex用量.app`. The app creates no database or cache directory of its own.

To also remove the interface-language preference, run:

```sh
defaults delete com.local.codexquotamenu
```

## Project Relationship

This is an independent community project. It is not affiliated with or endorsed by OpenAI.
