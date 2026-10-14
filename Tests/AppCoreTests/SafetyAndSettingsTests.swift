import Foundation
import SQLScript
import Testing
@testable import AppCore

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "moonrow-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Suite struct SafeModeTests {
    let read = ["select * from users", "show tables"]
    let mixed = ["select 1", "update users set name = 'x'"]

    @Test func requirementsPerLevel() {
        #expect(SafeMode.silent.requirement(for: mixed, dialect: .postgres) == .none)
        #expect(SafeMode.alert.requirement(for: read, dialect: .postgres) == .confirmation)
        #expect(SafeMode.alertWrites.requirement(for: read, dialect: .postgres) == .none)
        #expect(SafeMode.alertWrites.requirement(for: mixed, dialect: .postgres) == .confirmation)
        #expect(SafeMode.password.requirement(for: read, dialect: .mysql) == .password)
        #expect(SafeMode.passwordWrites.requirement(for: read, dialect: .mysql) == .none)
        #expect(SafeMode.passwordWrites.requirement(for: mixed, dialect: .mysql) == .password)
    }

    @Test func leavingAPasswordLevelNeedsThePassword() {
        #expect(SafeMode.silent.canChange(to: .password))
        #expect(SafeMode.alert.canChange(to: .silent))
        #expect(SafeMode.passwordWrites.canChange(to: .password))
        #expect(!SafeMode.passwordWrites.canChange(to: .alertWrites))
        #expect(!SafeMode.password.canChange(to: .passwordWrites))
        #expect(!SafeMode.password.canChange(to: .silent))
    }

    @Test func urlLevels() {
        #expect(SafeMode(level: 0) == .silent)
        #expect(SafeMode(level: 4) == .passwordWrites)
        #expect(SafeMode(level: 5) == nil)
    }

    @Test func credential() {
        let pw = SafetyCredential(password: "s3cret", connectionName: "Shop")
        #expect(pw.kind == .password)
        #expect(pw.matches("s3cret"))
        #expect(!pw.matches("Shop"))
        #expect(!pw.matches("s3cret "))
        let name = SafetyCredential(password: "", connectionName: "Shop")
        #expect(name.kind == .connectionName)
        #expect(name.matches("Shop"))
        #expect(!SafetyCredential(password: nil, connectionName: "Shop").matches(""))
    }
}

@Suite struct ConnectionMarkingTests {
    @Test func urlParameters() throws {
        let (c, _) = try #require(ConnectionConfig.parse(
            url: "postgres://u@db/shop?name=Shop%20live&statusColor=Red&env=production&safeModeLevel=2"))
        #expect(c.name == "Shop live")
        #expect(c.tagID == ConnectionTag.production.id)
        #expect(c.safeMode == .alertWrites)
        let (d, _) = try #require(ConnectionConfig.parse(url: "mysql://u@db/x?tag=staging&safeMode=password"))
        #expect(d.tagID == ConnectionTag.staging.id)
        #expect(d.safeMode == .password)
        // Tags are matched by name, ignoring case, among the ones given.
        let qa = ConnectionTag(name: "QA", color: .green)
        #expect(ConnectionConfig.parse(url: "mysql://u@db/x?tag=qa", tags: [qa])?.0.tagID == qa.id)
        #expect(ConnectionConfig.parse(url: "mysql://u@db/x?tag=qa")?.0.tagID == nil)
    }

    @Test func olderAndNewerFilesDecode() throws {
        let id = UUID()
        let old = #"{"id":"\#(id)","driver":"sqlite","filePath":"/tmp/a.db"}"#
        let c = try JSONDecoder().decode(ConnectionConfig.self, from: Data(old.utf8))
        #expect(c.safeMode == .silent && c.tagID == nil)
        // Tags saved by name before they could be edited become the default tag of that name;
        // the connection's own colour is dropped.
        let named = #"{"id":"\#(id)","driver":"sqlite","color":"blue","tag":"production"}"#
        #expect(try JSONDecoder().decode(ConnectionConfig.self, from: Data(named.utf8)).tagID == ConnectionTag.production.id)
        // Values from a newer version: an unknown tag is dropped, an unknown safe mode asks
        // before every statement.
        let newer = #"{"id":"\#(id)","driver":"sqlite","safeMode":"biometric","tag":"qa"}"#
        let n = try JSONDecoder().decode(ConnectionConfig.self, from: Data(newer.utf8))
        #expect(n.safeMode == .alert && n.tagID == nil)
    }

    @Test func roundTrip() throws {
        let c = ConnectionConfig(name: "x", filePath: "/tmp/x.db", safeMode: .passwordWrites, tagID: ConnectionTag.local.id)
        let back = try JSONDecoder().decode(ConnectionConfig.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        let tag = ConnectionTag(name: "QA", color: .green)
        #expect(try JSONDecoder().decode(ConnectionTag.self, from: JSONEncoder().encode(tag)) == tag)
        let unknown = #"{"id":"\#(tag.id)","name":"QA","color":"teal"}"#
        #expect(try JSONDecoder().decode(ConnectionTag.self, from: Data(unknown.utf8)).color == .gray)
    }
}

@MainActor
@Suite struct SettingsStoreTests {
    @Test func defaultsWhenMissingThenRoundTrip() throws {
        let url = SettingsStore.fileURL(root: tempDir())
        let store = SettingsStore(fileURL: url)
        #expect(store.load() == nil)
        #expect(store.settings == AppSettings())
        try store.update {
            $0.appearance = .dark
            $0.editorFontSize = 15
            $0.defaultSafeMode = .alertWrites
            $0.keyBindings["runAllQueries:"] = KeyBinding("r", [.command, .control])
            // Restating a default isn't kept.
            $0.keyBindings["runCurrentQuery:"] = KeyBinding("\r")
        }
        let again = SettingsStore(fileURL: url)
        #expect(again.load() == nil)
        #expect(again.settings == store.settings)
        #expect(again.settings.keyBindings.keys.sorted() == ["runAllQueries:"])
    }

    @Test func badValuesKeepDefaultsAndBadFilesAreKept() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = SettingsStore.fileURL(root: dir)
        try Data(#"{"appearance":"sepia","editorFontSize":400,"gridFontSize":14}"#.utf8).write(to: url)
        let store = SettingsStore(fileURL: url)
        #expect(store.load() == nil)
        #expect(store.settings.appearance == .system)
        #expect(store.settings.editorFontSize == AppSettings.editorFontSizes.upperBound)
        #expect(store.settings.gridFontSize == 14)

        try Data("{".utf8).write(to: url)
        #expect(store.load() != nil)
        #expect(store.settings == AppSettings())
        #expect(try String(contentsOf: url.appendingPathExtension("bak"), encoding: .utf8) == "{")
    }
}

@Suite struct KeymapTests {
    @Test func display() {
        #expect(KeyBinding("\r", [.command, .shift]).display == "⇧⌘↩")
        #expect(KeyBinding("[", [.command, .control]).display == "⌃⌘[")
        #expect(KeyBinding("P", [.command, .option]).display == "⌥⌘P")
        #expect(KeyBinding("\u{F705}", []).display == "F2")
        #expect(KeyBinding("\u{8}", .command).display == "⌘⌫")
        #expect(KeyBinding.empty.display == "")
    }

    @Test func validity() {
        #expect(KeyBinding("t").isValid)
        #expect(KeyBinding("t", [.control]).isValid)
        #expect(!KeyBinding("t", [.shift]).isValid)
        #expect(!KeyBinding("t", []).isValid)
        #expect(KeyBinding("\u{F708}", []).isValid)  // F5
        #expect(!KeyBinding.empty.isValid)
    }

    @Test func overridesAndConflicts() {
        var overrides: [String: KeyBinding] = [:]
        #expect(Keymap.binding(for: "runAllQueries:", overrides: overrides) == KeyBinding("\r", [.command, .shift]))
        // ⌘T is New Query Tab's.
        #expect(Keymap.conflicts(KeyBinding("t"), for: "runAllQueries:", overrides: overrides) == ["New Query Tab"])
        overrides["newQueryTab:"] = .empty
        #expect(Keymap.binding(for: "newQueryTab:", overrides: overrides)?.isEmpty == true)
        #expect(Keymap.conflicts(KeyBinding("t"), for: "runAllQueries:", overrides: overrides).isEmpty)
        // Its own shortcut isn't a conflict; fixed menu shortcuts are.
        #expect(Keymap.conflicts(KeyBinding("\r"), for: "runCurrentQuery:", overrides: [:]).isEmpty)
        #expect(Keymap.conflicts(KeyBinding("c"), for: "runCurrentQuery:", overrides: [:], fixed: [("Copy", KeyBinding("c"))]) == ["Copy"])
    }

    @Test func defaultsAreUnique() {
        // AppKit clears a shortcut that another main-menu item already has.
        let bindings = Keymap.commands.map(\.defaultBinding).filter { !$0.isEmpty }
        #expect(Set(bindings).count == bindings.count)
        // Space (right sidebar) and ⌥⌫ (truncate) have no ⌘; Save (⌘S is Commit) and the
        // M9–M11 commands have none.
        let unusual = Set(["toggleRightSidebar:", "truncateTable:", "saveQuery:", "showRunningQueries:",
                           "searchInDatabase:", "showDiagram:", "showTableDefinition:",
                           "exportTables:", "importJSON:", "importSQLFile:", "backupDatabases:", "restoreDatabase:"])
        #expect(Keymap.commands.allSatisfy { $0.defaultBinding.isValid || unusual.contains($0.id) })
        #expect(Keymap.command("saveQuery:")?.defaultBinding.isEmpty == true)
        #expect(Keymap.command("toggleRightSidebar:")?.defaultBinding.display == "Space")
    }

    /// AppKit reads a shifted letter from its case, so ⇧⌘S goes to the menu as "S".
    @Test func menuKeysCarryShiftInTheirCase() {
        #expect(KeyBinding("s", [.command, .shift]).menuKey == "S")
        #expect(KeyBinding("s").menuKey == "s")
        #expect(KeyBinding("\u{8}", [.command, .shift]).menuKey == "\u{8}")
        // Shifted punctuation goes to the menu as the character typed: ⇧⌘] is "}".
        #expect(KeyBinding("]", [.command, .shift]).menuKey == "}")
        #expect(KeyBinding("]", [.command, .option]).menuKey == "]")
        // A recorded ⇧⌘] ("}" with ⇧) is kept as "]" with ⇧, shown as ⇧⌘].
        #expect(KeyBinding("}", [.command, .shift]) == KeyBinding("]", [.command, .shift]))
        #expect(KeyBinding("}", [.command, .shift]).display == "⇧⌘]")
    }

    @Test func themes() {
        #expect(EditorTheme.named("nope") == EditorTheme.standard)
        for theme in EditorTheme.all {
            for palette in [theme.light, theme.dark] {
                for hex in [palette.background, palette.text, palette.keyword, palette.string, palette.number,
                            palette.comment, palette.identifier, palette.parameter, palette.lineNumber,
                            palette.currentStatement, palette.selection] {
                    #expect(EditorTheme.components(hex) != nil, "\(theme.id) \(hex)")
                }
            }
        }
        #expect(EditorTheme.components("#FF8000")! == (1, 128.0 / 255, 0))
    }
}
