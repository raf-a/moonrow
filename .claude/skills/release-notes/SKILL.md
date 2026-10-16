---
name: release-notes
description: Draft or revise a Moonrow release's notes, docs/release-notes/<version>.md, from the commits since the last tag, in the house style, then render and preview them as Sparkle's update window shows them. Use when preparing a release, when asked for release notes or a changelog, or when the notes for a version need rewriting.
---

# Release notes

Every release's notes follow `docs/release-notes/README.md`: the brand style, the shape, the writing rules and the rules for the Fixes and Improvements lists. Read it in full before writing, and treat it as the authority. The newest `docs/release-notes/<version>.md` is the worked example.

## 1. Settle the versions

- **The previous release** is `git describe --tags --abbrev=0` (or the tag the user names).
- **The new version** is the one the user names. If they haven't named one, propose the next minor version and say so.
- **For a version that already has notes,** revise that file rather than starting over.

## 2. Collect what changed

- Read `git log --format='=== %h %s%n%b' <previous>..HEAD`. The commit bodies say what each change does for people; the subjects alone aren't enough.
- **Sort every change into one bucket:**
  - **Features:** new things people can do. The biggest becomes the title, and one to three more become `##` sections.
  - **Improvements:** smaller changes people on the previous release will notice.
  - **Fixes:** things that were wrong *in the previous release*. To check, look the feature up at that tag (`git grep <name> <previous> -- Sources`). A fix to something new in this release isn't a fix.
  - **Left out:** tests, harnesses, refactors, docs, CI, wording-only changes nobody would miss.
- **Weigh every change before writing,** and show the user the ranking: who notices it (everyone, users of one pane, hardly anyone) and how often (all day, now and then). Then:
  - **The lead is what people use most,** not what took the most commits. The title names it.
  - **A fix everyone sees daily can also appear in the body,** written as what people gain. It still gets its line in Fixes.
  - **A change used now and then goes in Improvements,** even when it was a lot of work.
  - **Drop improvements hardly anyone would notice,** such as a fill colour. Fixes are the exception: list every bug the release resolves.
  - **Fewer, stronger points beat completeness.** Two body paragraphs and three list items is a full release.
- **Check every claim against the code before writing it:** menu titles, button titles and shortcuts as `Sources/Moonrow` spells them (`grep -rn "Go to Line" Sources/Moonrow`), defaults, and which databases a feature covers. When the code and a commit message disagree, the code wins.

## 3. Write

- Write `docs/release-notes/<version>.md` by the guide.
- **Say what each change is worth to people,** tied to something they can see: "so you can spot a past query at a glance", not "the SQL wraps to six lines". Leave layout details (which row a button sits on, an icon) out of the body.
- **Don't dwell on what was broken in the body.** It only says what people get now. Every resolved bug is still listed in Fixes, one plain line each.
- **No generic opener.** "The sidebar is now easier to read" fits any app; start with the change itself.
- **Before showing the user, reread it against the guide's Brand style and Writing sections,** one rule at a time. In particular, check the titles are names rather than slogans, the first sentences say what changed, there's no hype, every item has an area tag and a verb, and Fixes come before Improvements.
- **This repository is public:** follow `CLAUDE.md` and `CLAUDE.local.md` on what tracked files may mention.
- **Images:** suggest which feature would gain from a screenshot. Don't invent a file that doesn't exist; a release can have none.

## 4. Render and preview

```bash
swift scripts/render-release-notes.swift docs/release-notes/<version>.md > build/release-notes.html
```

Run SwiftPM and `swift` scripts outside the Bash sandbox. Open the page in the browser pane to read it.

To see the notes in Sparkle's own window, the way users will (it renders with WebKit, in a small box):

1. Build the app with `scripts/build-app.sh`.
2. Make a feed folder holding `appcast.xml` with one item. Give it a `sparkle:version` above the app's build number, `sparkle:shortVersionString` set to the version, and the rendered page inside `<description><![CDATA[…]]></description>`. The enclosure can point anywhere on `127.0.0.1`, since nothing gets downloaded.
3. Serve the folder: `python3 -m http.server 8765 --bind 127.0.0.1 --directory <folder>`, in the background.
4. Launch the app hidden:

   ```bash
   open -g -j -n --env MOONROW_BACKGROUND=1 --env MOONROW_STORE=<scratch>/connections.json --env MOONROW_FEED_URL=http://127.0.0.1:8765/appcast.xml --env MOONROW_UPDATE=check build/Moonrow.app
   ```

5. Capture the Software Update window with the computer-use `app_screenshot`, scroll it with `app_scroll`, and open Fixes or Improvements with `app_click` on their summaries. Don't take over the user's screen.
6. Afterwards, quit that instance (find it by `MOONROW_UPDATE=check` in `ps -Eww`) and stop the server.

If another Moonrow is running (the installed app, or a build in another worktree), `app_screenshot` may reach that one instead, since they share a bundle ID; never quit the user's instances. Instead, `ditto` the app to a scratch copy and launch the copy with `MOONROW_UPDATE=install` and `MOONROW_SNAPSHOTS=<scratch>/snaps`: it saves the update window as `update-1.png` before pressing Install Update, whose download then fails harmlessly against the test feed. Quit the copy once the file appears. The web view sometimes hasn't drawn yet and the notes box comes out blank; then read the page in the browser pane instead.

## 5. Hand over

Show the user the rendered result and list any claims you couldn't verify. Commit, tag or push only when they ask. Tagging `v<version>` publishes the release, and the workflow fails if the notes file is missing.
