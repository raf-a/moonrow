# Release notes

Each release has a notes file here, `<version>.md`, and Sparkle's update window shows it. The release workflow won't publish a tag without one. This page says how to write the notes so that every release reads the same. `docs/RELEASING.md` covers how they're rendered and previewed.

## Brand style

People keep Moonrow open all day, next to their editor and terminal. They usually meet the notes in a small window, just before they click Install. The notes should feel like the app itself: quiet, exact and quick to read.

- **Calm.** The notes inform; they don't sell. The reader has already chosen Moonrow. Confidence comes from specifics, not adjectives, and every release sounds the same, whatever its size.
- **Precise.** Every sentence names something real: a menu, a button, a shortcut or a behaviour. If a reader can't find it in the app, the sentence is wrong.
- **Brief.** The most useful change comes first, and the detail folds away below it. A reader who stops after the title and the first paragraph should still know what's new.
- **On the reader's side.** Say what they can do now and where to find it. In Fixes, say plainly what was broken, without apology or drama.

The page looks the way it reads:

- **Typography does the work:** the system font, a large title for the lead feature, and secondary text and dates in grey. Colour is kept for area tags and links. There are no banners, badges, gradients or emoji.
- **One order on every page:** the date, the title, a paragraph or two, the other features, then Fixes and Improvements folded.
- **Area tags** are small outlined pills with a coloured dot. Each area always has the same colour, so readers learn to scan for the ones they care about.
- **Screenshots** show the real app with sample data, cropped tight, with rounded corners and a hairline border.
- **The page follows the Mac's light or dark appearance.**

## Shape

```markdown
# Query folders

What's new, in a sentence. What you can do with it now.

![The Queries pane next to the folder in Finder](images/0.2.0-query-folders.png)

## Unsaved query indicators

The next feature, in a paragraph or two.

## Fixes

- [Results] Fixed pinned results showing the newest run's row count

## Improvements

- [Editor] Added Go to Line… (⌘L)
```

- **The title names the lead feature,** the one most people will notice. Then come one to three more features as `##` sections, in order of how useful they are. Use `###` for the parts of a large feature.
- **Fixes, then Improvements, come last** as lists. Each one folds in the update window.
- **Images:** at most one per feature. Put them in `images/<version>-<name>.png`. Use a crop of the window about 1000 px wide, with nothing personal in it. A release can have no images at all.

## Writing

The brand style, sentence by sentence.

- **Titles are the feature's name, in sentence case:** "Query folders", "Unsaved query indicators", "Error locations". Don't use slogans, puns, questions, "Introducing…" or "New:".
- **The first sentence says what changed, plainly,** usually with "now". For example: "Saved queries are now plain `.sql` files in a folder for each connection."
- **Then say what people can do with it,** in the second person and present tense: "Edit a query in another editor and the Queries pane shows the change."
- **For a larger change, one sentence on the problem can come first,** before the change itself: "A long script used to stop at its first error without saying where."
- **Give one concrete example** when the feature is abstract: "For example, …"
- **End by saying where to find the feature** if it isn't obvious: "Choose Edit ▸ Go to Line… or press ⌘L."
- **Keep paragraphs to one to three sentences.** A feature rarely needs more than two paragraphs.
- **Name the UI exactly as it reads:** menu paths with ▸ (Edit ▸ Complete), buttons by their titles (Fetch All), shortcuts as symbols (⌘L, ⇧⌘S, ⌃Space).
- **Describe behaviour, not implementation.** Never mention file-watching APIs, class names, refactors, tests or the dev harnesses.
- **Leave out hype and filler:** no exclamation marks, no emoji, no "powerful", "seamless", "blazing", "delightful", "simply", "just" or "we're excited". Use "we" only for a decision someone might question: "We removed the per-connection rows-per-page setting."
- **Spell as the app does,** with British spelling (colour, behaviour) and curly quotes and apostrophes (’ “ ”). Name macOS settings as Apple writes them.

## Fixes and Improvements

- **Each item is one line** that starts with an area tag in brackets, then what changed: `- [Editor] Added Go to Line… (⌘L)`.
- **Improvements start with** Added, Improved, Changed or Removed, or say what happens "now": "Search now matches the SQL as well as names". **Fixes start with** Fixed and describe what people saw go wrong, not the cause: "Fixed the last row of the parameters sheet being cut off".
- **No full stop at the end.**
- **Use these areas,** and add one only when nothing fits: Connections, Sidebar, Tables, Structure, Editor, Results, Queries, History, Safe mode, Import & Export, Backup, SSH, Postgres, MySQL, SQLite, Settings, Updates. Each tag gets its colour from its name.
- **Only list what people on the previous release can notice.** A fix to something new in this release isn't a fix; the feature's own text covers it. Leave out internal work.
- **Sort the items by area,** then by importance.
