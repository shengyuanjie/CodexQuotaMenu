# Codex Usage Menu Bar

English | [简体中文](README.md)

A native macOS menu bar utility that shows remaining Codex usage, reset countdowns, global bonus-reset probability, and active tasks, with an optional read-only Scriptable lock-screen widget feed.

![App icon](Resources/AppIcon-1024.png)

[Download the latest release](https://github.com/shengyuanjie/CodexQuotaMenu/releases/latest) · [Full usage guide](docs/product-and-usage.en.md) · [Privacy notice](PRIVACY.en.md) · [Support the project](#support-the-project)

## Features

- Shows the remaining percentage, exact reset time, and countdown for Codex usage windows.
- Shows every usage window returned by Codex and the current plan type.
- Uses `▶` for the number of tasks that are still active.
- Uses `↻48h` for the single next-48-hour global bonus-reset probability from Codex Reset Monitor.
- Lists recent active tasks in the menu and shows explicit error states.
- Refreshes every five seconds, supports an immediate manual refresh, and preserves the last successful result during temporary query failures.
- Refreshes the public forecast independently every five minutes and hides cached forecast data after two hours.
- Shows an encouragement message at an 80% reset probability, then restores normal quota details on both devices after detecting that both quota windows entered their next reset cycle.
- Provides an optional, default-off, token-protected local feed for an iPhone Scriptable lock-screen widget.
- Uses a text-only menu-bar display without a leading icon for a cleaner appearance.
- Supports Follow System, Simplified Chinese, and English interface languages.
- Can reconcile daily activation times with official Codex automations through a one-confirmation workflow; the app manages only its own prefixed tasks.
- Reuses your existing local Codex sign-in; no account token needs to be provided to this project.
- Contains no advertising, analytics, telemetry, or third-party runtime dependencies.

Completed tasks are not included in the menu bar counts, and no completed-task count is shown.

## Menu Bar Display

```text
Codex 90% · 4h 25m · ↻30% · ▶ 1
```

| Display | Meaning |
|---|---|
| `Codex 90%` | Remaining percentage for the shortest usage window |
| `4h 25m` | Time until that window resets |
| `↻30%` | Primary probability of a global bonus reset in the next 24 hours |
| `▶ 1` | Number of tasks that are still active |

Open the menu for every usage window, the 48-hour forecast and source, recent task titles, errors, and update times. The **Phone Widget** submenu controls the read-only local feed and copies its address or access token.

Global bonus-reset probabilities are public community forecasts. They express uncertainty and are neither an official schedule nor a guarantee.

The app no longer classifies tasks as waiting for user action and does not analyze response text to infer intent. Any task still marked active by Codex is counted under `▶`; a detected completion marker removes it from the count.

## Requirements

- macOS 14 or later.
- A signed-in Codex desktop app, Codex included with the ChatGPT desktop app, or Codex CLI.
- Download the `arm64` release for Apple Silicon or the `x86_64` release for an Intel Mac.

## Install

1. Download the ZIP matching your Mac from [GitHub Releases](https://github.com/shengyuanjie/CodexQuotaMenu/releases/latest).
2. Download the matching `.sha256` file and verify the archive.
3. Extract the ZIP and move `Codex用量.app` to Applications.
4. This project does not currently have an Apple Developer certificate. The app is ad-hoc signed with Hardened Runtime enabled, but it is not notarized. On first launch, you may need to right-click the app in Finder and select **Open**.

Do not download builds from unofficial mirror sites. Public release archives are built from version tags by this repository's GitHub Actions workflow.

## How to Use

1. Launch `Codex用量.app` from Applications. It has no main window or Dock icon; look for it in the macOS menu bar.
2. Read the remaining usage, reset countdown, and `▶` active-task count directly from the menu bar.
3. Click the item for details. Choose **Refresh Now**, or press `R` while the menu is open, to query immediately.
4. Choose **Language** to switch instantly between Follow System, Simplified Chinese, and English.
5. For a daily activation time, open **Activation Times…**, add the times you need each day, then choose **Sync to Codex**. The app copies a complete reconciliation prompt and opens a new Codex conversation; paste and send it once. The list is empty on first launch. The status shows **Synced** only after a local read-only reconciliation finds the saved settings and task configuration identical. You need to sync again only after changing a time; quitting CodexQuotaMenu does not affect created official background automations.
6. For an iPhone lock-screen display, follow the [Scriptable setup guide](mobile/README.md) and enable the **Phone Widget** read-only feed.
7. Choose **Quit**, or press `Q` while the menu is open, to stop all queries and the phone feed.

Managed task names use `CodexQuotaMenu · HH:mm`. Sync does not adopt existing tasks without that prefix; with an empty time list, its prompt cleans up only prefixed managed tasks. Successful scheduled runs are silent; Codex notifies according to its notification policy only when a run fails.

To start the app at login, open **System Settings → General → Login Items**, click **+**, and select `Codex用量.app` from Applications.

The app queries local usage and tasks every five seconds and refreshes public forecasts independently every five minutes. These are polling intervals, not server pushes. Scriptable suggests the earliest next refresh after five minutes, but iOS does not guarantee that schedule.

## Privacy

The app queries usage and task metadata through a local Codex process. To identify whether a task is still active or completed, it may parse structured lifecycle events from up to the last 512 KB of relevant local Codex session logs. It no longer analyzes response text to infer user intent.

To reconcile daily activation times, the app read-only scans `~/.codex/automations/*/automation.toml` and extracts only the configuration needed for reconciliation. It does not write those files, read automation run conversations, or upload automation configuration. A local check can confirm matching configuration, but cannot prove that an individual background run succeeded.

All session content is processed in memory. It is not copied, stored in a project database, uploaded, or used for telemetry.

Forecasting performs GET requests only to `codexreset.org/api/monitor-summary` and displays only its next-48-hour probability; no personal usage, task, identity, or Codex credential is sent. `UserDefaults` stores the public forecast cache and phone-feed toggle, while the phone access token is stored in macOS Keychain. The default-off phone response contains aggregate values only.

See the [English privacy notice](PRIVACY.en.md) for the complete statement.

## Security Boundaries

- App Sandbox is not enabled because the app must start a local Codex subprocess and read Codex session logs.
- Release builds use Hardened Runtime and ad-hoc signing, but are not trusted by Gatekeeper like a notarized Developer ID build.
- Codex itself may connect to OpenAI normally. This utility additionally contacts only the documented `codexreset.org` public forecast endpoint and sends it no personal data.
- Plain HTTP for the phone feed is intended only for a trusted LAN or an existing encrypted VPN/home tunnel. Never port-forward it to the public internet.
- See the [English security policy](SECURITY.en.md) for responsible vulnerability reporting.

## Troubleshooting

- **No window appears:** This is a menu bar app. Check the top of the screen; it has no normal window or Dock icon.
- **The menu stays on “Loading…” or `Codex --`:** Confirm that Codex or the ChatGPT desktop app is installed and signed in, then choose **Refresh Now** or restart this utility.
- **`▶ 1` remains when no task is running:** Refresh first. An abnormally interrupted task that receives no further updates stops counting as running after 30 minutes.
- **macOS cannot verify the developer:** Confirm that the archive came from this project's Release page and passed SHA-256 verification, then right-click the app in Finder and choose **Open**.

See the [full product and usage guide](docs/product-and-usage.en.md) for additional troubleshooting and uninstall instructions.

## Build from Source

Install Xcode Command Line Tools, then run:

```sh
./build-app.sh
```

The script creates a release build for the current Mac architecture, strips debug symbols and build-machine user paths, includes the app icon, enables Hardened Runtime, applies an ad-hoc signature, and verifies the bundle signature.

If Codex is installed in a nonstandard location, advanced users may set `CODEX_CLI_PATH` in the app's launch environment.

## Support the Project

If this project is useful to you, you can optionally support its ongoing maintenance through:

- [Afdian](https://afdian.com/a/520_00)
- [Ko-fi](https://ko-fi.com/520_00)

Donations do not affect downloads, features, updates, or issue reporting. These links appear only in the project documentation and GitHub Sponsor button; the app itself does not load or connect to either platform.

## License

Source code is released under the [MIT License](LICENSE). This independent community project is not affiliated with or endorsed by OpenAI, and its icon does not use official OpenAI or Codex trademarks.
