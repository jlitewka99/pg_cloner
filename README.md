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

1. Merge the intended changes into `main` and ensure CI is green.
2. Create and push a stable semantic-version tag:

   ```zsh
   git tag -a v1.0.0 -m 'PG Cloner 1.0.0'
   git push origin v1.0.0
   ```

3. The **Release beta** workflow tests, creates or reuses the GitHub Release, uploads the DMG/ZIP/checksums, signs `appcast.xml`, and deploys the latest feed and landing page to GitHub Pages.

Only `vMAJOR.MINOR.PATCH` tags publish releases. Re-running a failed workflow preserves the existing release asset and retries the signed Pages deployment.

## One-time repository setup

- In **Settings → Pages**, set **Source** to **GitHub Actions**.
- Protect `main` and tags matching `v*`; only trusted maintainers should create release tags.
- The signing key is stored in the login Keychain under the Sparkle account `com.pgcloner.app`; its public key is committed in `distribution/Info.plist`.
- `SPARKLE_ED25519_PRIVATE_KEY` is a repository Actions secret. It was initialized during this setup and must never be committed or printed. Export and back up the Keychain key before moving to another Mac; losing it prevents signing future updates with the same identity.

The workflow supplies that secret to Sparkle over standard input only. It does not use the key as a command-line argument or write it into build artifacts.

## Production hardening

Before distributing outside the internal beta group, migrate the release path to an Apple Developer ID certificate, Hardened Runtime, notarization, and stapling. The Sparkle feed URL and Ed25519 key can remain unchanged.
