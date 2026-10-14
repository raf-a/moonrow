# Releasing

1. Make sure `main` is green in CI.
2. Tag and push:

   ```bash
   git tag v1.2.0
   git push origin v1.2.0
   ```

   The `Release` workflow tests, builds a universal (arm64 + x86_64) `Moonrow.app` with version `1.2.0` and build number set to the run number, and publishes a GitHub release with `Moonrow-1.2.0.dmg`, `Moonrow-1.2.0.zip`, `SHA256SUMS` and `appcast.xml`. A tag with a hyphen, like `v1.2.0-rc.1`, publishes a prerelease.

Running the workflow by hand (Actions → Release → Run workflow) builds and packages without publishing; the files are attached to the run as an artifact.

## Signing and notarization

Without these, the app is signed ad hoc, and macOS blocks it on first launch until the user approves it. To sign with a Developer ID and notarize, add these to the repository (Settings → Secrets and variables → Actions):

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

Each update is signed with an EdDSA key. The public half is `SUPublicEDKey` in the app's `Info.plist` (set in `scripts/build-app.sh`); the private half is the repository secret:

| Name | Kind | Value |
|---|---|---|
| `SPARKLE_PRIVATE_KEY` | Secret | The private key, as `generate_keys -x <file>` from Sparkle's release tarball exports it |

After packaging, the workflow runs `scripts/make-appcast.sh`, which:

1. downloads Sparkle's tools at the version pinned in the script and checks the tarball's SHA-256;
2. signs `Moonrow-1.2.0.zip` with `sign_update`, passing the key on stdin;
3. checks that signature against the `SUPublicEDKey` of the app it just built, so a key that doesn't match fails the release;
4. writes `appcast.xml` with one item: the zip's download URL on the release, its signature and length, the build number and version, `minimumSystemVersion` 14.0, and a link to the release page as the release notes.

A tag without the secret fails; a manual run without it skips the appcast. When Sparkle moves to a new version, update the package and the version and checksum in `scripts/make-appcast.sh` together.

The key never changes: apps already installed only accept updates signed with the key they shipped with. Keep the exported file somewhere safe outside the repository.

## Xcode version

The workflows run on GitHub's `macos-26` image and pick the newest Xcode on it. To pin one, set the repository variable `XCODE_APP`, e.g. `/Applications/Xcode_27.0.app`.

## Locally

```bash
MOONROW_UNIVERSAL=1 MOONROW_VERSION=1.2.0 scripts/build-app.sh release
scripts/package-release.sh 1.2.0      # build/release/
```

Set `MOONROW_SIGN_IDENTITY` to sign with a Developer ID, and `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` to notarize.

To write the appcast too, with the private key in a file:

```bash
SPARKLE_PRIVATE_KEY_FILE=path/to/key scripts/make-appcast.sh 1.2.0 42 \
  https://github.com/raf-a/moonrow/releases/download/v1.2.0/Moonrow-1.2.0.zip \
  https://github.com/raf-a/moonrow/releases/tag/v1.2.0
```

### Testing an update

`MOONROW_SPARKLE_KEY` in `build-app.sh` builds with another public key, and `MOONROW_FEED_URL` points a build at another feed. To try a whole update without a release, build two versions with a test key and the same Developer ID, serve the newer one's zip and appcast from `127.0.0.1`, and run the older one from a copy:

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory <folder with the zip and appcast.xml>
open -n --env MOONROW_FEED_URL=http://127.0.0.1:8765/appcast.xml --env MOONROW_STORE=/tmp/moonrow-update/connections.json build/copy/Moonrow.app
```

With `--env MOONROW_UPDATE=install` as well, the app checks at launch and presses Install Update and Install and Relaunch itself. Sparkle relaunches the app through Launch Services, without these variables, so put them in the copies' `LSEnvironment` (and re-sign) to keep the relaunched app off the real connections.
