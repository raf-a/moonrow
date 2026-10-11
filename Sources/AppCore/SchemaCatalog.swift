import DBKit
import Foundation
import SQLScript

/// What autocomplete knows about a connection's schema: the object list, plus columns of the
/// tables a statement mentions, loaded the first time they're needed.
@MainActor
public final class SchemaCatalog {
    private let connection: any DatabaseConnection
    public private(set) var objects: [DatabaseObject] = []
    /// Keyed by lowercased table name.
    private var columns: [String: [String]] = [:]
    private var loading: Set<String> = []
    /// Called after columns arrive, so an open completion list can refresh.
    public var onChange: (() -> Void)?
    /// Posted (object: the catalog) after columns arrive.
    public static let didChange = Notification.Name("SchemaCatalog.didChange")

    public init(connection: any DatabaseConnection) {
        self.connection = connection
    }

    /// Replaces the object list (the sidebar loads it) and forgets loaded columns.
    public func setObjects(_ objects: [DatabaseObject]) {
        self.objects = objects
        columns = [:]
    }

    public var completionCatalog: SQLCompletion.Catalog {
        SQLCompletion.Catalog(
            tables: objects.filter { $0.kind == .table }.map(\.ref.name),
            views: objects.filter { $0.kind == .view || $0.kind == .materializedView }.map(\.ref.name),
            functions: SQLKeywords.functions,
            columns: columns)
    }

    public func hasColumns(of table: String) -> Bool { columns[table.lowercased()] != nil }

    /// Starts loading columns for any of `tables` that are known objects without columns yet.
    public func loadColumns(of tables: [String]) {
        for name in tables {
            let key = name.lowercased()
            guard columns[key] == nil, !loading.contains(key),
                  let object = objects.first(where: { $0.ref.name.lowercased() == key }) else { continue }
            loading.insert(key)
            Task {
                let list = (try? await connection.columns(of: object.ref).map(\.name)) ?? []
                loading.remove(key)
                columns[key] = list
                onChange?()
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
    }

    /// Waits until nothing is loading. For tests.
    public func idle() async {
        while !loading.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    }
}
