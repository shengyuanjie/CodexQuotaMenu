# Codex Usage Menu Bar

English | [简体中文](README.md)

A native macOS menu bar utility that shows remaining Codex usage, reset countdowns, global bonus-reset probability, and active tasks, with an optional read-only Scriptable lock-screen widget feed.

![App icon](Resources/AppIcon-1024.png)

[Download the latest release](https://github.com/shengyuanjie/CodexQuotaMenu/releases/latest) · [Full usage guide](docs/product-and-usage.en.md) · [Privacy notice](PRIVACY.en.md) · [Support the project](#support-the-project)

## Features

- Shows the remaining percentage, exact reset time, and countdown for Codex usage windows.
- Shows every usage window returned by Codex and the current plan type.
- Uses `▶` for the number of tasks that are still active.
- Uses `↻` for the primary 24-hour global bonus-reset probability. `⚡` is a separate fast Tibo signal and is never averaged into that probability.
- Lists recent active tasks in the menu and shows explicit error states.
- Refreshes every five seconds, supports an immediate manual refresh, and preserves the last successful result during temporary query failures.
- Refreshes public forecasts independently every five minutes and hides primary forecast cache data after two hours.
- Provides an optional, default-off, token-protected local feed for an iPhone Scriptable lock-screen widget.
- Uses a text-only menu-bar display without a leading icon for a cleaner appearance.
- Supports Follow System, Simplified Chinese, and English interface languages.
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

Open the menu for every usage window, 24/48-hour forecasts, confidence, the separate `⚡` signal, recent task titles, errors, and update times. The **Phone Widget** submenu controls the read-only local feed and copies its address or access token.

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
5. For an iPhone lock-screen display, follow the [Scriptable setup guide](mobile/README.md) and enable the **Phone Widget** read-only feed.
6. Choose **Quit**, or press `Q` while the menu is open, to stop all queries and the phone feed.

To start the app at login, open **System Settings → General → Login Items**, click **+**, and select `Codex用量.app` from Applications.

The app queries local usage and tasks every five seconds and refreshes public forecasts independently every five minutes. These are polling intervals, not server pushes. Scriptable's 15-minute refresh date is also only an iOS scheduling suggestion and is not guaranteed.

## Privacy

The app queries usage and task metadata through a local Codex process. To identify whether a task is still active or completed, it may read up to the last 512 KB of relevant local Codex session logs. It no longer analyzes response text to infer user intent.

All session content is processed in memory. It is not copied, stored in a project database, uploaded, or used for telemetry.

Forecasting performs GET requests only to `codex-reset.com/api/forecast` and `codexreset.org/api/monitor-summary`; no personal usage, task, identity, or Codex credential is sent. `UserDefaults` stores the public primary-forecast cache and the phone-feed toggle, while the phone access token is stored in macOS Keychain. The default-off phone response contains aggregate values only.

See the [English privacy notice](PRIVACY.en.md) for the complete statement.

## Security Boundaries

- App Sandbox is not enabled because the app must start a local Codex subprocess and read Codex session logs.
- Release builds use Hardened Runtime and ad-hoc signing, but are not trusted by Gatekeeper like a notarized Developer ID build.
- Codex itself may connect to OpenAI normally. This utility additionally contacts only the two documented public forecast endpoints and sends them no personal data.
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
