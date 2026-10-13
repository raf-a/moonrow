import Foundation

/// App-wide preferences, saved as JSON next to the connections.
public struct AppSettings: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, Sendable, CaseIterable {
        case system, light, dark

        public var title: String {
            switch self {
            case .system: "Match System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    public var appearance: Appearance = .system
    /// An `EditorTheme` id.
    public var editorTheme: String = EditorTheme.standard.id
    /// A font family; empty uses the system's monospaced font.
    public var editorFontName: String = ""
    public var editorFontSize: Double = 13
    public var gridFontSize: Double = 12
    public var alternatingRows: Bool = true
    /// The safe mode new connections start with.
    public var defaultSafeMode: SafeMode = .silent
    /// Shortcuts changed in the Keymap preferences, by command id; `.empty` removes one.
    public var keyBindings: [String: KeyBinding] = [:]
    /// Reopen the workspaces that were open at quit, with their tabs.
    public var reopenWorkspaces: Bool = true
    /// Ask for values of `:name`, `$1` and `?` placeholders before running (QueryParameters).
    public var queryParameters: Bool = true
    /// What the query editor's Run button runs; the other is in its menu.
    public var runButtonRunsAll: Bool = false
    /// Settings ▸ Locations: the folder holding pg_dump, pg_restore and psql; empty finds them.
    public var postgresToolsFolder: String = ""
    /// The folder holding mysqldump and mysql (or MariaDB's); empty finds them.
    public var mysqlToolsFolder: String = ""

    public init() {}

    public static let editorFontSizes: ClosedRange<Double> = 9...32
    public static let gridFontSizes: ClosedRange<Double> = 9...24

    public var theme: EditorTheme { EditorTheme.named(editorTheme) }

    private enum CodingKeys: String, CodingKey {
        case appearance, editorTheme, editorFontName, editorFontSize, gridFontSize, alternatingRows
        case defaultSafeMode, keyBindings, reopenWorkspaces, queryParameters, runButtonRunsAll
        case postgresToolsFolder, mysqlToolsFolder
    }

    // Each value is read on its own: one that's missing or not understood keeps its default
    // instead of losing the rest.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = AppSettings()
        appearance = value(.appearance, d.appearance)
        editorTheme = value(.editorTheme, d.editorTheme)
        editorFontName = value(.editorFontName, d.editorFontName)
        editorFontSize = min(max(value(.editorFontSize, d.editorFontSize), Self.editorFontSizes.lowerBound), Self.editorFontSizes.upperBound)
        gridFontSize = min(max(value(.gridFontSize, d.gridFontSize), Self.gridFontSizes.lowerBound), Self.gridFontSizes.upperBound)
        alternatingRows = value(.alternatingRows, d.alternatingRows)
        defaultSafeMode = value(.defaultSafeMode, d.defaultSafeMode)
        keyBindings = value(.keyBindings, d.keyBindings)
        reopenWorkspaces = value(.reopenWorkspaces, d.reopenWorkspaces)
        queryParameters = value(.queryParameters, d.queryParameters)
        runButtonRunsAll = value(.runButtonRunsAll, d.runButtonRunsAll)
        postgresToolsFolder = value(.postgresToolsFolder, d.postgresToolsFolder)
        mysqlToolsFolder = value(.mysqlToolsFolder, d.mysqlToolsFolder)
    }

    /// Finds the backup tools with the folders chosen here.
    public var toolLocator: ToolLocator {
        ToolLocator(folders: [.postgres: postgresToolsFolder, .mysql: mysqlToolsFolder])
    }
}

/// Loads and saves `AppSettings`. Every change is written at once.
@MainActor
public final class SettingsStore {
    /// Posted after every change.
    public static let didChange = Notification.Name("SettingsStore.didChange")

    public let fileURL: URL
    public private(set) var settings = AppSettings()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `settings.json` in the same folder as the connections file.
    public static func fileURL(root: URL) -> URL { root.appending(path: "settings.json") }

    /// A missing file means defaults. A file that can't be read is renamed to
    /// `settings.json.bak` (so it's never overwritten) and the defaults are used; the error is
    /// returned for the caller to mention.
    @discardableResult
    public func load() -> (any Error)? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            settings = AppSettings()
            return nil
        } catch {
            settings = AppSettings()
            return error
        }
        do {
            settings = try JSONDecoder().decode(AppSettings.self, from: data)
            return nil
        } catch {
            settings = AppSettings()
            let backup = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return error
        }
    }

    public func update(_ change: (inout AppSettings) -> Void) throws {
        var next = settings
        change(&next)
        next.keyBindings = Keymap.normalized(next.keyBindings)
        guard next != settings else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(next).write(to: fileURL, options: .atomic)
        settings = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// Colours for the SQL editor, one palette per appearance. Colours are `#RRGGBB`.
public struct EditorTheme: Sendable, Hashable, Identifiable {
    public struct Palette: Sendable, Hashable {
        public var background: String
        public var text: String
        public var keyword: String
        public var string: String
        public var number: String
        public var comment: String
        public var identifier: String
        public var parameter: String
        public var lineNumber: String
        /// Behind the statement ⌘↩ would run.
        public var currentStatement: String
        public var selection: String
    }

    public var id: String
    public var name: String
    public var light: Palette
    public var dark: Palette

    public static let standard = EditorTheme(
        id: "standard", name: "Standard",
        light: Palette(
            background: "#FFFFFF", text: "#1D1D21", keyword: "#B0308F", string: "#C2311F", number: "#2A3FC9",
            comment: "#6A7782", identifier: "#126E8C", parameter: "#B5520E", lineNumber: "#A3A8AD",
            currentStatement: "#F2F6FC", selection: "#B5D3FF"),
        dark: Palette(
            background: "#1F2023", text: "#E1E1E3", keyword: "#F470B4", string: "#F7806E", number: "#D9C77A",
            comment: "#808D99", identifier: "#6BCFF0", parameter: "#F49B5A", lineNumber: "#5C6066",
            currentStatement: "#272A30", selection: "#3F5E8C"))

    public static let paper = EditorTheme(
        id: "paper", name: "Paper",
        light: Palette(
            background: "#FAF7F0", text: "#2E2A24", keyword: "#8A3B12", string: "#3E7A2C", number: "#7A4FA0",
            comment: "#9A9183", identifier: "#1F5F8B", parameter: "#B4532A", lineNumber: "#B9B1A3",
            currentStatement: "#F2EDE1", selection: "#E8DCC2"),
        dark: Palette(
            background: "#23211D", text: "#E6DFD3", keyword: "#E39A6B", string: "#A7C98A", number: "#C7A3E6",
            comment: "#8C8475", identifier: "#89B8DB", parameter: "#E8A06E", lineNumber: "#5F594E",
            currentStatement: "#2C2925", selection: "#4A4338"))

    public static let contrast = EditorTheme(
        id: "contrast", name: "High Contrast",
        light: Palette(
            background: "#FFFFFF", text: "#000000", keyword: "#0000C8", string: "#A30000", number: "#006B00",
            comment: "#5A5A5A", identifier: "#7A007A", parameter: "#9A4A00", lineNumber: "#5A5A5A",
            currentStatement: "#EDEDED", selection: "#9CC3FF"),
        dark: Palette(
            background: "#000000", text: "#FFFFFF", keyword: "#7CB7FF", string: "#FF8A80", number: "#9CFF9C",
            comment: "#B0B0B0", identifier: "#F0A0FF", parameter: "#FFC266", lineNumber: "#9A9A9A",
            currentStatement: "#1C1C1C", selection: "#2F5C99"))

    public static let all = [standard, paper, contrast]

    /// Unknown ids fall back to the standard theme.
    public static func named(_ id: String) -> EditorTheme { all.first { $0.id == id } ?? standard }

    /// `#RRGGBB` → components in 0…1; nil if malformed.
    public static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}
