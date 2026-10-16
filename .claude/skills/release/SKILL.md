---
name: release
description: Prepare a Moonrow release end to end, up to a checked GitHub draft that the user publishes. Checks main, CI and code scanning, writes and previews the release notes, brings the README's feature list up to date, commits them, tags, waits for the Release workflow, then checks the draft's files and shows the update window people will get. Use when the user wants to release, ship or cut a version.
argument-hint: "[major | minor | patch | <version>]"
---

# Release

This skill takes a version from `main` to a **draft** GitHub release that has been checked from end to end. It never publishes. Publishing on GitHub is the user's sign-off, and it's the moment the update reaches everyone: Sparkle reads `releases/latest/download/appcast.xml`, and a draft isn't "latest".

`docs/RELEASING.md` is the reference for the workflow, signing, the appcast and the notes. Run `gh`, `swift`, `codesign`, `spctl` and `scripts/*` outside the Bash sandbox: `gh` fails its TLS checks inside it, and `codesign` and `spctl` can report a valid signature as invalid.

Keep the task list current. Stop and report at the first check that fails; don't work around it.

## 1. Check that main can ship

Check each of these, and report them together:

- **The working tree:** the branch is `main`, and it's clean apart from release notes and the README. After `git fetch origin`, it is neither behind nor ahead of `origin/main`, except for an unpushed notes commit.
- **CI:** CI passed on the commit being released, or on the last code commit before a notes-only commit: `gh run list --workflow ci.yml --branch main --limit 5 --json headSha,conclusion,status`. If it failed or is still running, stop and say so. A failed run gets `gh run view <id> --log-failed`, summed up in a line or two.
- **Code scanning:** `scripts/check-release-scan.sh` (main by default) shows main's latest CodeQL scans and any open errors or high or critical security alerts. The Release workflow scans the tag itself and runs the same check before it drafts, so an alert here would block the release later: list the alerts and stop. A missing scan isn't a reason to stop, because the release scans anyway; mention it.
- **The version** comes from the skill's argument, counted from the last release tag (`git describe --tags --abbrev=0 --match 'v[0-9]*'`, without the `v`):
  - `major`, `minor` or `patch` bumps that part and resets the ones after it. From `0.1.0`, that's `1.0.0`, `0.2.0` or `0.1.1`. If the last tag is a prerelease (`1.2.0-rc.1`), bump from its release version (`1.2.0`).
  - An explicit version such as `1.2.0` or `1.2.0-rc.1` is used as given. It must be later than the last tag.
  - With no argument, propose the next minor version.
  - Anything else: ask which one was meant.

  Say which version this works out to, starting from which tag, and get a yes before going on. `v<version>` must be on neither the local repository nor the remote (`git ls-remote --tags origin v<version>`), and there must be no release of it (`gh release view v<version>` fails).
- **Secrets:** `gh secret list --env release`, or the repository's own `gh secret list` while they're still there, includes `SPARKLE_PRIVATE_KEY`, `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD` and `NOTARY_KEY`, and `gh variable list` includes `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`. Without the Sparkle key the release fails. Without the others it's unsigned or not notarized, so ask before going on.
- **Other drafts:** `gh release list` shows any older draft. Mention it, but leave it alone.

## 2. Write the notes

Invoke the `release-notes` skill for this version and follow it through its preview, including Sparkle's window. Show the user the rendered notes and get their approval of the text before going on. Changes to the notes after the tag mean a new tag, so this is the time to get them right.

## 3. Update the README

The README's feature list is the app's public page, so it should cover what this release adds. Compare the notes' features with the list under `## Features` in `README.md`, and change the list only where a new feature is one people would choose Moonrow for. Most releases change nothing, or one bullet.

- **It's a marketing page for people,** not a changelog or a help page. Write one simple bulleted list: a bold name, then a line on what people get.
- **Follow the brand style** in `docs/release-notes/README.md`: calm, precise and brief. Leave out hype, slogans as names, idioms ("make it your own") and padding ("so you can see what went wrong").
- **No help-page details:** menu paths, settings locations, shortcuts and tool names stay out.
- **Fold a feature into the bullet it belongs to** before adding a new one. Keep the list to about ten bullets, ordered by how much people use each feature.
- **Only list what ships,** and check each claim against the code as the notes are checked.

Show the user the diff and get their approval before going on. If nothing needs to change, say so.

## 4. Commit and tag

Ask once, in a single message, for the go-ahead to do the three outward steps:

1. Commit `docs/release-notes/<version>.md`, any images in `docs/release-notes/images/` and a changed `README.md` on `main` as "Add the <version> release notes", following the repository's commit rules. The hooks must pass; never bypass them.
2. Run `git push origin main`.
3. Run `git tag v<version>` on that commit, then `git push origin v<version>`. This starts the Release workflow, which only makes a draft.

If the notes were already committed and pushed, skip the first two steps and say so.

## 5. Wait for the workflow

- Find the run: `gh run list --workflow release.yml --limit 5 --json databaseId,headBranch,event,status,url`. It's the one whose `headBranch` is `v<version>`.
- Wait with `gh run watch <id> --exit-status` as a background command (a release takes 15–30 minutes with notarization), and don't poll in between. Tell the user the run's URL while it builds.
- If it fails, read `gh run view <id> --log-failed` and say which step failed and why. Common causes are a code scanning alert on the tag (the `publish` job's check lists it), a missing notes file, a test failure, a signing or notarization error, or an EdDSA key that doesn't match the app's.
- Don't retry by deleting and re-pushing the tag without asking (see Recovery below).

## 6. Check the draft

```bash
scripts/check-release.sh <version> build/check-<version>
```

It downloads the draft and checks everything a user's Mac will check: the checksums, the appcast against the zip, the EdDSA signature against the app's own key, the version and build number, both architectures, the Developer ID signature, notarization and stapling of the app and the DMG, and the DMG's contents. Every line must be `ok`.

Then look at the result as a user would:

1. **The downloaded app launches.** Open `build/check-<version>/zip/Moonrow.app` hidden, with a scratch store:

   ```bash
   open -g -j -n --env MOONROW_BACKGROUND=1 --env MOONROW_STORE=<scratch>/connections.json build/check-<version>/zip/Moonrow.app
   ```

   Then capture its Connections window with the computer-use `app_screenshot`, and check that it shows the new version. Quit it afterwards.
2. **The update window people will get.** Serve the draft's own `appcast.xml` from `build/check-<version>` on `127.0.0.1` (`python3 -m http.server 8765 --bind 127.0.0.1 --directory build/check-<version>`, in the background). Launch the locally built `build/Moonrow.app` with `MOONROW_FEED_URL=http://127.0.0.1:8765/appcast.xml` and `MOONROW_UPDATE=check`, as the `release-notes` skill describes. Screenshot the Software Update window. Don't press Install Update: the zip's URL only works once the release is published. Quit the app and stop the server afterwards.

Never click around the user's screen; the `app_*` tools work in the background.

## 7. Hand over

Give the user:

- the draft's URL (`gh release view v<version> --json url --jq .url`)
- the outcome of every check, and the two screenshots
- a reminder that publishing the draft (Edit → Publish release) releases it: every copy of Moonrow with automatic checks on is offered the update at its next check. The notes and appcast are dated the day the workflow ran.

**Publishing is the user's step,** and it's their validation. Publish only if they explicitly ask you to (`gh release edit v<version> --draft=false`); otherwise, tell them where the button is.

When the user says it's published, confirm that the feed serves it:

```bash
curl -sL https://github.com/raf-a/moonrow/releases/latest/download/appcast.xml | grep shortVersionString
```

It should show the new version. A prerelease never shows there, by design.

## Recovery

If a check fails or the user rejects the draft, nothing has reached users yet. Fix the cause on `main` first. Then, **with the user's go-ahead**, remove the draft and its tag, and run steps 4 to 7 again:

```bash
gh release delete v<version> --yes --cleanup-tag
git tag -d v<version>
```

The version can be reused, because the draft was never published, and the next workflow run gives it a new build number. Never delete or retag a **published** release; ship a new version instead.
