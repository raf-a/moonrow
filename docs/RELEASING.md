# Releasing

1. Make sure `main` is green in CI.
2. Tag and push:

   ```bash
   git tag v1.2.0
   git push origin v1.2.0
   ```

   The `Release` workflow tests, builds a universal (arm64 + x86_64) `Moonrow.app` with version `1.2.0` and build number set to the run number, and publishes a GitHub release with `Moonrow-1.2.0.dmg`, `Moonrow-1.2.0.zip` and `SHA256SUMS`. A tag with a hyphen, like `v1.2.0-rc.1`, publishes a prerelease.

Running the workflow by hand (Actions → Release → Run workflow) builds and packages without publishing; the files are attached to the run as an artifact.

## Signing and notarization

Without secrets, the app is signed ad hoc and users have to approve it on first launch (see the README). To sign with a Developer ID and notarize, add these to the repository (Settings → Secrets and variables → Actions):

| Name | Kind | Value |
|---|---|---|
| `MACOS_CERTIFICATE` | Secret | `base64 -i DeveloperID.p12`: a *Developer ID Application* certificate with its private key |
| `MACOS_CERTIFICATE_PASSWORD` | Secret | The `.p12` password |
| `NOTARY_KEY` | Secret | `base64 -i AuthKey_XXXX.p8`: an App Store Connect API key with the Developer role |
| `NOTARY_KEY_ID` | Variable | The key's ID |
| `NOTARY_ISSUER_ID` | Variable | The issuer ID shown on the API keys page |

With only the certificate, releases are signed but not notarized.

## Xcode version

The workflows run on GitHub's `macos-26` image and pick the newest Xcode on it. To pin one, set the repository variable `XCODE_APP`, e.g. `/Applications/Xcode_27.0.app`.

## Locally

```bash
MOONROW_UNIVERSAL=1 MOONROW_VERSION=1.2.0 scripts/build-app.sh release
scripts/package-release.sh 1.2.0      # build/release/
```

Set `MOONROW_SIGN_IDENTITY` to sign with a Developer ID, and `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` to notarize.
