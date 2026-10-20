# Releasing

The `/release` skill walks through all of this: it checks `main`, writes the notes, tags, waits for the workflow and checks the draft it makes. By hand:

1. Make sure `main` is green in CI, and that `scripts/check-release-scan.sh` shows no alerts (see [Code scanning](#code-scanning)).
2. Write the release notes in `docs/release-notes/1.2.0.md` (see [Release notes](#release-notes)) and commit them.
3. Tag and push:

   ```bash
   git tag v1.2.0
   git push origin v1.2.0
   ```

   The `Release` workflow scans the tag with CodeQL (see [Code scanning](#code-scanning)), tests, builds a universal (arm64 + x86_64) `Moonrow.app` with version `1.2.0` and build number set to the run number, and drafts a GitHub release with `Moonrow-1.2.0.dmg`, `Moonrow-1.2.0.zip`, `SHA256SUMS` and `appcast.xml`. A tag with a hyphen, like `v1.2.0-rc.1`, drafts a prerelease.
4. Check the draft with `scripts/check-release.sh 1.2.0`. It downloads the draft's files and checks the checksums, the appcast against the zip, the EdDSA signature, the version and build number, the architectures, the Developer ID signature and notarization, and the DMG. Then publish the draft on GitHub (Releases → the draft → Edit → Publish release). Until then nobody can download it, and the update feed still offers the previous release. The release notes and the appcast are dated the day the workflow ran, so publish soon after.

Running the workflow by hand (Actions → Release → Run workflow) builds and packages without a release; the files are attached to the run as an artifact, with the newest release notes rendered as `release-notes.html`.

## Release notes

Sparkle's update window shows each release's notes, written by hand in `docs/release-notes/<version>.md`. A tag without its notes fails before the build; a prerelease such as `v1.2.0-rc.1` uses `1.2.0.md`. The GitHub release page shows the same notes, above GitHub's generated list of pull requests and new contributors.

[`docs/release-notes/README.md`](release-notes/README.md) says how to write them: the brand style, their shape and the area tags on Fixes and Improvements. The `/release-notes` skill drafts them from the commits since the last tag. Images go in `docs/release-notes/images/` and are loaded from the tagged commit on GitHub.

`scripts/render-release-notes.swift` turns the notes into a page dated today, which `scripts/make-appcast.sh` embeds in `appcast.xml`. To preview them, render them and open the page:

```bash
swift scripts/render-release-notes.swift docs/release-notes/1.2.0.md > build/release-notes.html
open build/release-notes.html
```

To see them in Sparkle's own window, put that page in a test appcast (as in [Testing an update](#testing-an-update)) and launch with `--env MOONROW_UPDATE=check`, which leaves the update window up.

## Code scanning

CodeQL scans the workflows on every pull request (`codeql.yml`, under a minute) and the Swift code on main (`codeql-swift.yml`), after each push that changes `Sources/`, `Package.swift` or `Package.resolved`, every Monday, and on demand (Actions → CodeQL Swift → Run workflow). The Swift scan has to watch a full build, about 20 minutes, so pull requests don't wait for it.

A release scans its own tag: the Release workflow runs both scans alongside the build, and its `publish` job drafts the release only when all three passed and `scripts/check-release-scan.sh <tag ref> <commit>` finds both scans of that commit and no open CodeQL alert that's an error, or a security alert rated high or critical. A release takes about 20 minutes, the length of the Swift scan. If an alert blocks it, fix it on main (or dismiss it on GitHub if it's a false positive), then delete the tag and tag again; nothing was drafted.

`scripts/check-release-scan.sh` on its own checks main's latest scans and alerts, a quick look before tagging.

## Signing and notarization

Without these, the app is signed ad hoc, and macOS blocks it on first launch until the user approves it. To sign with a Developer ID and notarize, add these to the repository (Settings → Secrets and variables → Actions). The secrets go in the `release` environment (Settings → Environments → release), which only `v*` tags and `main` can use; the variables stay on the repository:

| Name | Kind | Value |
|---|---|---|
| `MACOS_CERTIFICATE` | Secret | `base64 -i DeveloperID.p12`: a *Developer ID Application* certificate with its private key |
| `MACOS_CERTIFICATE_PASSWORD` | Secret | The `.p12` password |
| `NOTARY_KEY` | Secret | `base64 -i AuthKey_XXXX.p8`: an App Store Connect API key with the Developer role |
| `NOTARY_KEY_ID` | Variable | The key's ID |
| `NOTARY_ISSUER_ID` | Variable | The issuer ID shown on the API keys page |

With only the certificate, releases are signed but not notarized.

## Updates

The app updates itself with [Sparkle](https://sparkle-project.org). It reads its feed from `https://github.com/raf-a/moonrow/releases/latest/download/appcast.xml`, which GitHub serves from the newest release that isn't a prerelease, so prereleases are never offered. Sparkle compares build numbers (`sparkle:version`, the workflow's run number) and shows the version (`sparkle:shortVersionString`, e.g. `1.2.0`).

Each update is signed with an EdDSA key. The public half is `SUPublicEDKey` in the app's `Info.plist` (set in `scripts/build-app.sh`); the private half is a secret in the `release` environment:

| Name | Kind | Value |
|---|---|---|
| `SPARKLE_PRIVATE_KEY` | Secret | The private key, as `generate_keys -x <file>` from Sparkle's release tarball exports it |

After packaging, the workflow runs `scripts/make-appcast.sh`, which:

1. downloads Sparkle's tools at the version pinned in the script and checks the tarball's SHA-256;
2. signs `Moonrow-1.2.0.zip` with `sign_update`, passing the key on stdin;
3. checks that signature against the `SUPublicEDKey` of the app it just built, so a key that doesn't match fails the release;
4. writes `appcast.xml` with one item: the zip's download URL on the release, its signature and length, the build number and version, `minimumSystemVersion` 14.0, and the rendered release notes.

A tag without the secret fails; a manual run without it skips the appcast. When Sparkle moves to a new version, update the package and the version and checksum in `scripts/make-appcast.sh` together.

The key never changes: apps already installed only accept updates signed with the key they shipped with. Keep the exported file somewhere safe outside the repository.

## Xcode version

The workflows run on GitHub's `macos-26` image and pick the newest Xcode on it. To pin one, set the repository variable `XCODE_APP`, e.g. `/Applications/Xcode_27.0.app`.

## Backup tools

The app carries its own pg_dump, pg_restore, psql, mysqldump, mysql, mariadb-dump and mariadb, built from the vendors' source by `scripts/build-tools.sh` into `build/tools` (versions and checksums are at the top of the script). The release workflow caches them until the script or `scripts/tools-patches/` changes; a clean build takes a while. A universal or signed `build-app.sh` fails without them.

## Locally

```bash
scripts/build-tools.sh                # once; build/tools
MOONROW_UNIVERSAL=1 MOONROW_VERSION=1.2.0 scripts/build-app.sh release
scripts/package-release.sh 1.2.0      # build/release/
```

Set `MOONROW_SIGN_IDENTITY` to sign with a Developer ID, and `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` to notarize.

To write the appcast too, with the private key in a file:

```bash
swift scripts/render-release-notes.swift docs/release-notes/1.2.0.md \
  https://raw.githubusercontent.com/raf-a/moonrow/v1.2.0/docs/release-notes/ > build/release-notes.html
SPARKLE_PRIVATE_KEY_FILE=path/to/key scripts/make-appcast.sh 1.2.0 42 \
  https://github.com/raf-a/moonrow/releases/download/v1.2.0/Moonrow-1.2.0.zip \
  build/release-notes.html
```

### Testing an update

`MOONROW_SPARKLE_KEY` in `build-app.sh` builds with another public key, and `MOONROW_FEED_URL` points a build at another feed. To try a whole update without a release, build two versions with a test key and the same Developer ID, serve the newer one's zip and appcast from `127.0.0.1`, and run the older one from a copy:

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory <folder with the zip and appcast.xml>
open -n --env MOONROW_FEED_URL=http://127.0.0.1:8765/appcast.xml --env MOONROW_STORE=/tmp/moonrow-update/connections.json build/copy/Moonrow.app
```

With `--env MOONROW_UPDATE=install` as well, the app checks at launch and presses Install Update and Install and Relaunch itself. Sparkle relaunches the app through Launch Services, without these variables, so put them in the copies' `LSEnvironment` (and re-sign) to keep the relaunched app off the real connections.
