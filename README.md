# PG Cloner

Native macOS tool for cloning selected PostgreSQL tables and their dependencies.

## Install the beta

Download the current DMG from the [GitHub Releases](https://github.com/jlitewka99/pg_cloner/releases) page, drag **PG Cloner.app** into Applications, then open it once with Control-click → **Open**.

This beta is signed with Sparkle's Ed25519 update key, but is intentionally not signed with Apple Developer ID or notarized. Gatekeeper may therefore require confirmation on the first launch. Subsequent updates are verified by Sparkle before installation.

The update feed is available at:

`https://jlitewka99.github.io/pg_cloner/appcast.xml`

Choose **PG Cloner → Check for Updates…** in the app to check immediately. Sparkle also performs its normal periodic background checks.

## Development

```zsh
scripts/test_unit.sh
scripts/release.sh
```

`scripts/release.sh` uses Xcode when it is available and writes local artifacts to `dist/`.

To make versioned release artifacts locally:

```zsh
RELEASE_VERSION=1.0.0 RELEASE_BUILD=1.0.0 scripts/release.sh
```

This creates a universal app, `PG-Cloner-v1.0.0.dmg`, a Sparkle-compatible `PG-Cloner-v1.0.0.zip`, and SHA-256 checksum files.

## Publishing a beta

1. Update `MARKETING_VERSION` to the intended `MAJOR.MINOR.PATCH` version in the release PR.
2. Merge the PR into `main` after CI is green.

The **Release beta** workflow validates the version, tests and builds the app, then creates the matching `vMAJOR.MINOR.PATCH` tag, GitHub Release, signed appcast, and GitHub Pages download page. A merge that keeps an already released version does not publish anything.

If a release fails after its tag is created, re-run the workflow: it verifies that the tag points to the same commit and resumes publication.

## One-time repository setup

- In **Settings → Pages**, set **Source** to **GitHub Actions**.
- Protect `main` with pull requests and the `test-and-build` check; protect `v*` tags from updates and deletions.
- The signing key is stored in the login Keychain under the Sparkle account `com.pgcloner.app`; its public key is committed in `distribution/Info.plist`.
- `SPARKLE_ED25519_PRIVATE_KEY` is a repository Actions secret. It was initialized during this setup and must never be committed or printed. Export and back up the Keychain key before moving to another Mac; losing it prevents signing future updates with the same identity.

The workflow supplies that secret to Sparkle over standard input only. It does not use the key as a command-line argument or write it into build artifacts.

## Production hardening

Before distributing outside the internal beta group, migrate the release path to an Apple Developer ID certificate, Hardened Runtime, notarization, and stapling. The Sparkle feed URL and Ed25519 key can remain unchanged.
