// Turns a release's notes, docs/release-notes/<version>.md, into the HTML page Sparkle's update
// window shows, dated today.
// Usage: swift scripts/render-release-notes.swift <notes.md> [<image base URL>] > notes.html
//
// The notes are a small Markdown subset: `# Title` first, then paragraphs, `##` and `###`
// headings, `- ` lists, images on lines of their own, and **bold**, *italic*, `code` and
// [links](…) inline. A `##` section that holds nothing but a list, like Fixes or Improvements,
// folds, and an item that starts with `[Area]` shows the area as a tag. Image paths resolve
// against the base URL; without one, against the notes' folder, so a local preview shows them.
// docs/release-notes/README.md says how to write the notes.
import Foundation

let args = CommandLine.arguments
guard args.count == 2 || args.count == 3 else {
    FileHandle.standardError.write(Data("usage: render-release-notes.swift <notes.md> [<image base URL>]\n".utf8))
    exit(2)
}
let notesURL = URL(fileURLWithPath: args[1])
guard let source = try? String(contentsOf: notesURL, encoding: .utf8) else {
    FileHandle.standardError.write(Data("error: can't read \(args[1])\n".utf8))
    exit(1)
}
let imageBase = args.count == 3 ? URL(string: args[2]) : notesURL.deletingLastPathComponent()

enum Block {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([String])
    case image(alt: String, src: String)
}

// MARK: Blocks

let imageLine = try! NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(([^)\s]+)\)$"#)

func parse(_ text: String) -> [Block] {
    var blocks: [Block] = []
    var paragraph: [String] = []
    var items: [String]?

    func flushParagraph() {
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
        paragraph = []
    }
    func flushList() {
        if let list = items { blocks.append(.list(list)) }
        items = nil
    }

    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            flushParagraph()
            continue
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            flushParagraph()
            items = (items ?? []) + [String(line.dropFirst(2))]
            continue
        }
        // An indented line carries on the list item above it.
        if raw.first == " " || raw.first == "\t", paragraph.isEmpty, var list = items {
            list[list.count - 1] += " " + line
            items = list
            continue
        }
        flushList()
        if let hashes = line.firstIndex(where: { $0 != "#" }), line[hashes] == " ",
           case let level = line.distance(from: line.startIndex, to: hashes), (1...3).contains(level) {
            flushParagraph()
            blocks.append(.heading(level: level, text: String(line[hashes...]).trimmingCharacters(in: .whitespaces)))
        } else if let match = imageLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            flushParagraph()
            blocks.append(.image(alt: String(line[Range(match.range(at: 1), in: line)!]),
                                 src: String(line[Range(match.range(at: 2), in: line)!])))
        } else {
            paragraph.append(line)
        }
    }
    flushParagraph()
    flushList()
    return blocks
}

// MARK: Inline

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

let inlineRules: [(NSRegularExpression, String)] = [
    (#"\[([^\]]+)\]\(([^)\s]+)\)"#, #"<a href="$2">$1</a>"#),
    (#"\*\*(.+?)\*\*"#, "<strong>$1</strong>"),
    (#"(?<![\w*])[*_](?![\s*_])(.+?)(?<![\s*_])[*_](?![\w*])"#, "<em>$1</em>"),
].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

func inline(_ text: String) -> String {
    // Odd pieces are code spans, which take no other markup.
    text.components(separatedBy: "`").enumerated().map { index, piece in
        if index % 2 == 1 { return "<code>\(escape(piece))</code>" }
        var html = escape(piece)
        for (rule, template) in inlineRules {
            html = rule.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: template)
        }
        return html
    }.joined()
}

func imageSource(_ src: String) -> String {
    escape(URL(string: src, relativeTo: imageBase)?.absoluteString ?? src)
}

// MARK: Page

func render(_ blocks: [Block]) -> String {
    var html: [String] = []
    var index = 0
    while index < blocks.count {
        switch blocks[index] {
        case let .heading(1, text):
            html.append("<h1>\(inline(text))</h1>")
        case let .heading(2, text):
            // A section that's only a list folds, as long change lists do.
            let rest = blocks[(index + 1)...].prefix { if case .heading(let level, _) = $0 { level > 2 } else { true } }
            if rest.count == 1, case let .list(items) = rest.first! {
                html.append("<details><summary>\(inline(text))</summary>\(list(items))</details>")
                index += 2
                continue
            }
            html.append("<h2>\(inline(text))</h2>")
        case let .heading(_, text):
            html.append("<h3>\(inline(text))</h3>")
        case let .paragraph(text):
            html.append("<p>\(inline(text))</p>")
        case let .list(items):
            html.append(list(items))
        case let .image(alt, src):
            html.append(#"<img src="\#(imageSource(src))" alt="\#(escape(alt))">"#)
        }
        index += 1
    }
    return html.joined(separator: "\n")
}

let areaTag = try! NSRegularExpression(pattern: #"^\[([^\]]+)\]\s+(?!\()"#)

/// Each area keeps its colour from release to release: the areas docs/release-notes/README.md
/// lists have their own, and any other picks one by its name.
let areaColours = [
    "connections": "#5e6ad2", "sidebar": "#95a2b3", "tables": "#4cb782", "structure": "#26b5ce",
    "editor": "#bb87fc", "results": "#f2994a", "queries": "#e2b93b", "history": "#a3804f",
    "safe mode": "#eb5757", "import & export": "#26b5ce", "backup": "#4cb782", "ssh": "#95a2b3",
    "postgres": "#4f8fd8", "mysql": "#f2994a", "sqlite": "#26b5ce", "settings": "#95a2b3",
    "updates": "#4cb782",
]
let tagColours = ["#26b5ce", "#4cb782", "#f2994a", "#eb5757", "#5e6ad2", "#bb87fc", "#e2b93b", "#95a2b3"]

func colour(of area: String) -> String {
    let name = area.lowercased()
    // A stable hash: Swift's own hashValue changes from run to run.
    return areaColours[name] ?? tagColours[name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % tagColours.count]
}

func list(_ items: [String]) -> String {
    "<ul>" + items.map { item in
        guard let match = areaTag.firstMatch(in: item, range: NSRange(item.startIndex..., in: item)) else {
            return "<li>\(inline(item))</li>"
        }
        let area = String(item[Range(match.range(at: 1), in: item)!])
        let rest = String(item[Range(match.range, in: item)!.upperBound...])
        return #"<li><span class="tag" style="--tag: \#(colour(of: area))">\#(escape(area))</span> \#(inline(rest))</li>"#
    }.joined() + "</ul>"
}

let style = """
:root {
  color-scheme: light dark;
  --title: #1d1d1f;
  --text: #3a3a3f;
  --muted: #86868b;
  --rule: rgba(0, 0, 0, 0.09);
  --fill: rgba(0, 0, 0, 0.05);
  --link: #0a64d6;
}
@media (prefers-color-scheme: dark) {
  :root {
    --title: rgba(255, 255, 255, 0.94);
    --text: rgba(255, 255, 255, 0.74);
    --muted: rgba(255, 255, 255, 0.45);
    --rule: rgba(255, 255, 255, 0.1);
    --fill: rgba(255, 255, 255, 0.07);
    --link: #5aa9ff;
  }
}
html { background: transparent; }
body {
  margin: 0;
  padding: 20px 24px 28px;
  font: 13px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
  color: var(--text);
  -webkit-font-smoothing: antialiased;
}
time { display: block; margin-bottom: 6px; font-size: 12px; color: var(--muted); }
h1, h2, h3, summary { color: var(--title); font-weight: 600; }
h1 { margin: 0 0 14px; font-size: 22px; line-height: 1.25; letter-spacing: -0.02em; }
h2 { margin: 28px 0 6px; font-size: 16px; line-height: 1.3; letter-spacing: -0.012em; }
h3 { margin: 18px 0 4px; font-size: 13px; }
p { margin: 0 0 12px; }
img {
  display: block;
  max-width: 100%;
  height: auto;
  margin: 16px 0 20px;
  border: 1px solid var(--rule);
  border-radius: 10px;
}
ul { margin: 0 0 12px; padding-left: 18px; }
li { margin: 4px 0; }
li::marker { color: var(--muted); }
a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }
code {
  padding: 1px 5px;
  border-radius: 4px;
  background: var(--fill);
  font: 12px ui-monospace, SFMono-Regular, Menlo, monospace;
}
strong { color: var(--title); font-weight: 600; }
details { margin-top: 22px; border-top: 1px solid var(--rule); padding-top: 12px; }
details + details { margin-top: 0; }
summary { cursor: default; list-style: none; font-size: 13px; }
summary::-webkit-details-marker { display: none; }
summary::before {
  content: "";
  display: inline-block;
  width: 5px;
  height: 5px;
  margin: 0 10px 2px 2px;
  border-right: 1.5px solid var(--muted);
  border-bottom: 1.5px solid var(--muted);
  transform: rotate(-45deg);
  transition: transform 0.15s;
}
details[open] summary::before { transform: rotate(45deg); }
details ul { margin: 8px 0 4px; font-size: 12.5px; }
details li { margin: 6px 0; }
.tag {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  margin-right: 3px;
  padding: 0 7px;
  border: 1px solid var(--rule);
  border-radius: 999px;
  color: var(--title);
  font-size: 11px;
  font-weight: 500;
  line-height: 17px;
  white-space: nowrap;
}
.tag::before {
  content: "";
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--tag);
}
"""

let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.timeZone = TimeZone(identifier: "UTC")
formatter.dateFormat = "MMMM d, yyyy"
let isoFormatter = ISO8601DateFormatter()
isoFormatter.formatOptions = [.withFullDate]
let now = Date()

print("""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="light dark">
<style>
\(style)
</style>
</head>
<body>
<time datetime="\(isoFormatter.string(from: now))">\(formatter.string(from: now))</time>
\(render(parse(source)))
</body>
</html>
""")
