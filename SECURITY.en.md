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

## Release Boundaries

- The project currently has no Apple Developer certificate. Releases use Hardened Runtime and an ad-hoc signature but are not notarized.
- Public releases should be built only by this repository's GitHub Actions workflow from version tags.
- Every app archive is published with a matching SHA-256 file.
- Release auditing rejects binaries containing build-machine user paths or common credential patterns.
