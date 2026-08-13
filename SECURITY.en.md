# Security Policy

English | [简体中文](SECURITY.md)

## Supported Versions

Only the latest GitHub Release is maintained. Upgrade from an older release to receive security fixes.

## Reporting a Vulnerability

Do not disclose exploitable details, credentials, or personal session content in a public issue. Use the repository's **Security → Report a vulnerability** private reporting feature.

A useful report may include:

- the affected app and macOS versions;
- minimal reproduction steps;
- actual impact and expected behavior;
- redacted log fragments.

Do not submit account tokens, API keys, passwords, complete session logs, or another person's personal information.

## Phone Feed Security Boundary

- The phone feed is off by default and accepts only `GET /v1/widget`. It cannot refresh or control Codex, execute tasks, or read conversations.
- First enablement generates a 32-byte token with the system secure random source and stores it in macOS Keychain. The token is sent only in the `Authorization: Bearer` header.
- Requests are limited to 8 KiB and closed if incomplete after five seconds. Error responses never echo the token, request headers, or internal error stacks.
- JSON contains only personal quota, reset dates, running-task count, and public forecast summaries—never task titles, paths, conversations, or Codex credentials.
- The Mac service uses plain HTTP and is suitable only for a trusted LAN or an existing encrypted VPN/home tunnel. Never port-forward or expose port `47821` to the public internet.
- If a token may have leaked, regenerate it immediately from the menu. The old token becomes invalid at once. Never include a real token in a vulnerability report.

## External Forecast Boundary

The app makes public GET requests only to `codexreset.org/api/monitor-summary` and uses only its next-48-hour probability. It sends no personal usage, task, identity, session, or Codex credential data.

## Release Boundaries

- The project currently has no Apple Developer certificate. Releases use Hardened Runtime and an ad-hoc signature but are not notarized.
- Public releases should be built only by this repository's GitHub Actions workflow from version tags.
- Every app archive is published with a matching SHA-256 file.
- Release auditing rejects binaries containing build-machine user paths or common credential patterns.
- Automated tests use fixed fixtures and do not access a real Keychain or third-party forecast endpoint.
