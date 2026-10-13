import Foundation
import SQLScript

/// What the definition editor shows as its CREATE statement: views, materialized views,
/// routines and triggers.
public enum DefinitionKind: String, Sendable, Hashable, CaseIterable, Codable {
    case view, materializedView, function, procedure, trigger

    public init?(_ kind: ObjectKind) {
        switch kind {
        case .view: self = .view
        case .materializedView: self = .materializedView
        case .function: self = .function
        case .procedure: self = .procedure
        case .table, .sequence: return nil
        }
    }

    /// The sidebar's kind; nil for triggers, which belong to a table.
    public var objectKind: ObjectKind? {
        switch self {
        case .view: .view
        case .materializedView: .materializedView
        case .function: .function
        case .procedure: .procedure
        case .trigger: nil
        }
    }

    /// As DDL writes it: `MATERIALIZED VIEW`.
    public var keyword: String {
        switch self {
        case .view: "VIEW"
        case .materializedView: "MATERIALIZED VIEW"
        case .function: "FUNCTION"
        case .procedure: "PROCEDURE"
        case .trigger: "TRIGGER"
        }
    }

    /// For messages: "materialized view".
    public var title: String {
        switch self {
        case .materializedView: "materialized view"
        default: rawValue
        }
    }
}

/// An object in the database whose definition is edited as text.
public struct DefinedObject: Sendable, Hashable {
    public var kind: DefinitionKind
    /// Schema and name. A trigger's schema is its table's.
    public var ref: TableRef
    /// Postgres routines: the identity arguments (see `DatabaseObject.signature`).
    public var signature: String?
    /// Triggers: the table the trigger is on.
    public var table: TableRef?

    public init(kind: DefinitionKind, ref: TableRef, signature: String? = nil, table: TableRef? = nil) {
        self.kind = kind
        self.ref = ref
        self.signature = signature
        self.table = table
    }

    public init?(_ object: DatabaseObject) {
        guard let kind = DefinitionKind(object.kind) else { return nil }
        self.init(kind: kind, ref: object.ref, signature: object.signature)
    }

    public static func trigger(_ name: String, on table: TableRef) -> DefinedObject {
        DefinedObject(kind: .trigger, ref: TableRef(schema: table.schema, name), table: table)
    }

    /// The sidebar's object; nil for triggers.
    public var object: DatabaseObject? {
        kind.objectKind.map { DatabaseObject(ref, kind: $0, signature: signature) }
    }
}

/// The head of a `CREATE … {VIEW | MATERIALIZED VIEW | FUNCTION | PROCEDURE | TRIGGER} name`
/// statement: which kind it creates and under what name.
public struct DefinitionHead: Sendable, Hashable {
    public var kind: DefinitionKind
    /// The name as written, unquoted; with its schema when qualified.
    public var name: TableRef
    /// Quoted names keep their case; unquoted ones compare ignoring it.
    public var isQuoted: Bool
    /// UTF-16 range of the name, schema included.
    public var nameRange: Range<Int>
    /// Just after `CREATE`.
    public var afterCreate: Int
    public var orReplace: Bool

    public static func parse(_ statement: String, dialect: LexerDialect) -> DefinitionHead? {
        guard let scan = CreateScan(statement, dialect: dialect) else { return nil }
        let kind: DefinitionKind
        switch scan.keyword {
        case "VIEW": kind = scan.materialized ? .materializedView : .view
        case "FUNCTION": kind = .function
        case "PROCEDURE": kind = .procedure
        case "TRIGGER": kind = .trigger
        default: return nil
        }
        guard let name = scan.name else { return nil }
        return DefinitionHead(
            kind: kind, name: name.ref, isQuoted: name.isQuoted, nameRange: name.range,
            afterCreate: scan.afterCreate, orReplace: scan.orReplace)
    }

    /// Whether the statement names `other` (case-insensitively unless the name was quoted).
    public func names(_ other: String) -> Bool {
        isQuoted ? name.name == other : name.name.lowercased() == other.lowercased()
    }
}

/// Splitting and rewriting definition text.
public enum DefinitionText {
    /// The statements of a definition. MySQL marks the end of a routine's `BEGIN … END` only
    /// with a client `DELIMITER` line, so without one the whole text is one statement (its
    /// trailing `;` dropped); elsewhere the splitter knows `$$` and trigger bodies.
    public static func statements(_ text: String, dialect: LexerDialect) -> [String] {
        if dialect.delimiterCommand, !hasDelimiterLine(text) {
            let lexer = SQLLexer(text, dialect: dialect)
            let tokens = lexer.tokens()
            guard let first = tokens.firstIndex(where: { !$0.kind.isTrivia && $0.kind != .semicolon }),
                  let last = tokens.lastIndex(where: { !$0.kind.isTrivia && $0.kind != .semicolon })
            else { return [] }
            // Leading comments stay with the statement, as the splitter keeps them.
            let start = tokens[..<first].firstIndex { $0.kind.isComment }.map { tokens[$0].range.lowerBound }
                ?? tokens[first].range.lowerBound
            return [lexer.text(start..<tokens[last].range.upperBound)]
        }
        return SQLSplitter.split(text, dialect: dialect).map(\.text)
    }

    private static func hasDelimiterLine(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("DELIMITER ")
        }
    }

    /// `CREATE OR REPLACE …`, unless it says so already.
    public static func orReplace(_ statement: String, _ head: DefinitionHead) -> String {
        guard !head.orReplace else { return statement }
        var units = Array(statement.utf16)
        units.insert(contentsOf: Array(" OR REPLACE".utf16), at: head.afterCreate)
        return String(decoding: units, as: UTF16.self)
    }

    /// The statement with its object renamed (the schema as written is kept).
    public static func renaming(_ statement: String, _ head: DefinitionHead, to name: String,
                                quote: (String) -> String) -> String {
        var units = Array(statement.utf16)
        let written = (head.name.schema.map { quote($0) + "." } ?? "") + quote(name)
        units.replaceSubrange(head.nameRange, with: Array(written.utf16))
        return String(decoding: units, as: UTF16.self)
    }

    /// A `CREATE TABLE` or `CREATE INDEX` statement under another name (and, for an index, on
    /// another table). Only the names in the head change, never a column that happens to share
    /// them. Nil when the head can't be read.
    public static func renamingCreate(_ statement: String, dialect: LexerDialect, to name: String, onTable table: String? = nil,
                                      quote: (String) -> String) -> String? {
        guard let scan = CreateScan(statement, dialect: dialect), let target = scan.name else { return nil }
        var edits: [(Range<Int>, String)] = [(target.lastRange, quote(name))]
        if let table {
            guard let on = scan.onTable else { return nil }
            edits.append((on.lastRange, quote(table)))
        }
        var units = Array(statement.utf16)
        for (range, text) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            units.replaceSubrange(range, with: Array(text.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// Reads `CREATE [OR REPLACE] [modifiers] KIND [IF NOT EXISTS] [schema.]name [… ON [schema.]table]`.
struct CreateScan {
    struct Name {
        var ref: TableRef
        var isQuoted: Bool
        /// Schema included.
        var range: Range<Int>
        /// The name without its schema.
        var lastRange: Range<Int>
    }

    var keyword = ""
    var materialized = false
    var orReplace = false
    var afterCreate = 0
    var name: Name?
    /// The table after `ON` (indexes, triggers).
    var onTable: Name?

    private static let kinds: Set<String> = ["TABLE", "VIEW", "FUNCTION", "PROCEDURE", "TRIGGER", "INDEX"]

    init?(_ sql: String, dialect: LexerDialect) {
        let lexer = SQLLexer(sql, dialect: dialect)
        let tokens = lexer.tokens().filter { !$0.kind.isTrivia }
        func upper(_ i: Int) -> String { i < tokens.count ? lexer.text(tokens[i].range).uppercased() : "" }
        func isWord(_ i: Int) -> Bool { i < tokens.count && (tokens[i].kind == .word || tokens[i].kind == .keyword) }
        guard isWord(0), upper(0) == "CREATE" else { return nil }
        afterCreate = tokens[0].range.upperBound
        var i = 1
        // Modifiers come before the kind: OR REPLACE, TEMP, UNIQUE, ALGORITHM=…, DEFINER=…,
        // SQL SECURITY …, CONSTRAINT, MATERIALIZED. Give up at anything that ends a head.
        while i < tokens.count, i < 24 {
            let word = upper(i)
            if isWord(i), Self.kinds.contains(word) { break }
            if tokens[i].kind == .semicolon || word == "(" || (isWord(i) && ["AS", "ON"].contains(word)) { return nil }
            if word == "OR", upper(i + 1) == "REPLACE" { orReplace = true }
            if word == "MATERIALIZED" { materialized = true }
            i += 1
        }
        guard i < tokens.count, isWord(i) else { return nil }
        keyword = upper(i)
        i += 1
        if upper(i) == "IF", upper(i + 1) == "NOT", upper(i + 2) == "EXISTS" { i += 3 }

        func readName(at i: inout Int) -> Name? {
            func part(_ i: Int) -> (String, Bool)? {
                guard i < tokens.count else { return nil }
                let t = tokens[i]
                switch t.kind {
                case .word, .keyword: return (lexer.text(t.range), false)
                case .quotedIdentifier: return (Self.unquote(lexer.text(t.range)), true)
                default: return nil
                }
            }
            guard let first = part(i) else { return nil }
            let start = tokens[i].range.lowerBound
            if i + 2 < tokens.count, tokens[i + 1].kind == .punctuation, lexer.text(tokens[i + 1].range) == ".",
               let second = part(i + 2) {
                let name = Name(ref: TableRef(schema: first.0, second.0), isQuoted: second.1,
                                range: start..<tokens[i + 2].range.upperBound, lastRange: tokens[i + 2].range)
                i += 3
                return name
            }
            let name = Name(ref: TableRef(first.0), isQuoted: first.1, range: tokens[i].range, lastRange: tokens[i].range)
            i += 1
            return name
        }
        name = readName(at: &i)
        guard name != nil else { return nil }
        if keyword == "INDEX" || keyword == "TRIGGER" {
            // The table follows the first ON at the top level (a trigger's timing and events come first).
            var depth = 0
            while i < tokens.count {
                let w = upper(i)
                if w == "(" { depth += 1 } else if w == ")" { depth -= 1 }
                if depth == 0, isWord(i), w == "ON" {
                    i += 1
                    onTable = readName(at: &i)
                    break
                }
                i += 1
            }
        }
    }

    static func unquote(_ s: String) -> String {
        guard let open = s.first, s.count >= 2 else { return s }
        let close: Character = open == "[" ? "]" : open
        var inner = String(s.dropFirst().dropLast())
        if open != "[" { inner = inner.replacingOccurrences(of: String([close, close]), with: String(close)) }
        return inner
    }
}

// MARK: - Plans

/// How an edited definition replaces the object in the database.
public enum ReplaceMethod: Sendable, Hashable {
    /// `CREATE OR REPLACE`: privileges and dependent objects stay.
    case orReplace
    /// DROP the old object, then run the text.
    case dropFirst
    /// For databases that apply DDL as it runs (MySQL routines): create the new text under a
    /// scratch name first, so a definition that doesn't compile leaves the old one in place,
    /// then drop the scratch and the old object and run the text.
    case checkThenDrop
}

extension Dialect {
    /// The DDL that makes the database hold `text`: new objects run it as written; an existing
    /// `object` is replaced as `replaceMethod(for:)` says. When the text names another object
    /// than `object`, the old one is dropped first (renaming by editing the name).
    public func definitionPlan(replacing object: DefinedObject?, kind: DefinitionKind, text: String) throws -> DDLPlan {
        guard supportsDefinitions(of: kind) else { throw DatabaseError("\(name) has no \(kind.title)s.") }
        let statements = DefinitionText.statements(text, dialect: lexer)
        guard !statements.isEmpty else { throw DatabaseError("The \(kind.title)'s definition is empty.") }
        guard let object else { return DDLPlan(statements: statements, isAtomic: transactionalDDL) }

        let heads = statements.map { DefinitionHead.parse($0, dialect: lexer) }
        guard let main = heads.firstIndex(where: { $0?.kind == object.kind }), let head = heads[main] else {
            throw DatabaseError("The text needs a CREATE \(object.kind.keyword) statement.")
        }
        let drop = try dropStatement(object)
        let renamed = !head.names(object.ref.name)
        switch replaceMethod(for: object.kind) {
        case .orReplace where !renamed:
            var out = statements
            out[main] = DefinitionText.orReplace(statements[main], head)
            return DDLPlan(statements: out, isAtomic: transactionalDDL)
        case .orReplace, .dropFirst:
            var notes: [String] = []
            if !transactionalDDL {
                notes.append("\(name) applies each statement as it runs: if the new definition fails, the old \(object.kind.title) is already gone.")
            }
            return DDLPlan(statements: [drop] + statements, isAtomic: transactionalDDL, notes: notes)
        case .checkThenDrop:
            let scratch = String(("moonrow_check_" + head.name.name).prefix(64))
            let check = DefinitionText.renaming(statements[main], head, to: scratch, quote: quoteIdentifier)
            let dropCheck = try dropStatement(DefinedObject(kind: object.kind, ref: TableRef(schema: head.name.schema, scratch)))
            return DDLPlan(
                statements: [check, dropCheck, drop] + statements, isAtomic: false,
                notes: ["\(name) can't replace a \(object.kind.title) in place: the new one is created under a scratch name first to check it, then the old one is dropped."])
        }
    }
}
