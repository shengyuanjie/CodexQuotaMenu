# Codex Usage Menu Bar

English | [简体中文](README.md)

A native macOS menu bar utility that shows your remaining Codex usage, reset countdown, and the number of tasks that are running or waiting for you.

![App icon](Resources/AppIcon-1024.png)

See the [English product and usage guide](docs/product-and-usage.en.md) for detailed instructions.

## Features

- Shows the remaining percentage and reset countdown for Codex usage windows.
- Uses `▶` for tasks that are running normally.
- Uses `⏸` for tasks waiting for approval, a choice, manual input, an upload, or a reply.
- Supports Follow System, Simplified Chinese, and English interface languages.
- Reuses your existing local Codex sign-in; no account token needs to be provided to this project.
- Contains no advertising, analytics, telemetry, or third-party runtime dependencies.

## Requirements

- macOS 14 or later.
- A signed-in Codex desktop app, Codex included with the ChatGPT desktop app, or Codex CLI.
- Download the `arm64` release for Apple Silicon or the `x86_64` release for an Intel Mac.

## Install

1. Download the ZIP matching your Mac from GitHub Releases.
2. Download the matching `.sha256` file and verify the archive.
3. Extract the ZIP and move `Codex用量.app` to Applications.
4. This project does not currently have an Apple Developer certificate. The app is ad-hoc signed with Hardened Runtime enabled, but it is not notarized. On first launch, you may need to right-click the app in Finder and select **Open**.

Do not download builds from unofficial mirror sites. Public release archives are built from version tags by this repository's GitHub Actions workflow.

## Change the Interface Language

Open the menu bar item, select **Language**, then choose:

- Follow System;
- Simplified Chinese;
- English.

The change takes effect immediately. The selected language is stored locally in macOS preferences.

## Privacy

The app queries usage and task metadata through a local Codex process. To identify running, waiting, and completed tasks, it may read up to the last 512 KB of relevant local Codex session logs. This may include task titles and the current turn's response.

All such content is processed in memory. It is not copied, stored in a project database, uploaded, or used for telemetry. The only setting persisted by this app is the selected interface language.

See the [English privacy notice](PRIVACY.en.md) for the complete statement.

## Security Boundaries

- App Sandbox is not enabled because the app must start a local Codex subprocess and read Codex session logs.
- Release builds use Hardened Runtime and ad-hoc signing, but are not trusted by Gatekeeper like a notarized Developer ID build.
- Codex itself may connect to OpenAI as part of its normal operation; this utility does not implement its own upload service.
- See the [English security policy](SECURITY.en.md) for responsible vulnerability reporting.

## Start at Login

Open **System Settings → General → Login Items**, click **+**, and select `Codex用量.app`.

## Build from Source

Install Xcode Command Line Tools, then run:

```sh
./build-app.sh
```

The script creates a release build for the current Mac architecture, strips debug symbols and build-machine user paths, includes the app icon, enables Hardened Runtime, applies an ad-hoc signature, and verifies the bundle signature.

If Codex is installed in a nonstandard location, advanced users may set `CODEX_CLI_PATH` in the app's launch environment.

## License

Source code is released under the [MIT License](LICENSE). This independent community project is not affiliated with or endorsed by OpenAI, and its icon does not use official OpenAI or Codex trademarks.
