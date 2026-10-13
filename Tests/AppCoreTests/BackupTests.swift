import DBKit
import DriverMySQL
import DriverPostgres
import Foundation
import Testing
import WireSupport
@testable import AppCore

struct DumpToolTests {
    @Test func versions() {
        #expect(ToolInfo.parse("pg_dump (PostgreSQL) 18.1\n").version == [18, 1])
        #expect(ToolInfo.parse("pg_dump (PostgreSQL) 16.4 (Homebrew)").version == [16, 4])
        let mysql = ToolInfo.parse("mysqldump  Ver 9.5.0 for macos15.4 on arm64 (Homebrew)")
        #expect(mysql.version == [9, 5, 0] && !mysql.mariaDB)
        let oldMaria = ToolInfo.parse("mysqldump  Ver 10.19 Distrib 10.11.6-MariaDB, for osx10.19 (arm64)")
        #expect(oldMaria.version == [10, 11, 6] && oldMaria.mariaDB)
        let maria = ToolInfo.parse("mariadb-dump from 11.4.2-MariaDB, client 10.19 for osx10.19 (arm64)")
        #expect(maria.version == [11, 4, 2] && maria.mariaDB)
    }

    @Test func splittingExtraArguments() throws {
        #expect(try ToolCommand.splitArguments("") == [])
        #expect(try ToolCommand.splitArguments(#"--jobs=4  --exclude-table="my table" -T 'a b' x\ y"#)
            == ["--jobs=4", "--exclude-table=my table", "-T", "a b", "x y"])
        #expect(try ToolCommand.splitArguments(#"--a="" 'it''s'"#) == ["--a=", "its"])
        #expect(throws: DatabaseError.self) { try ToolCommand.splitArguments("'open") }
        #expect(ToolCommand.shellQuoted("plain-1.sql") == "plain-1.sql")
        #expect(ToolCommand.shellQuoted("it's here") == #"'it'\''s here'"#)
    }

    @Test func locatorPrefersTheChosenFolderAndNewestCopy() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let versions = ["a": "pg_dump (PostgreSQL) 16.2", "b": "pg_dump (PostgreSQL) 18.0", "c": "mysqldump  Ver 10.19 Distrib 11.4.2-MariaDB"]
        for (folder, _) in versions {
            let dir = root.appending(path: folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = folder == "c" ? "mysqldump" : "pg_dump"
            FileManager.default.createFile(atPath: dir.appending(path: name).path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let lookup: @Sendable (String) -> String? = { path in
            versions[URL(filePath: path).deletingLastPathComponent().lastPathComponent]
        }
        let paths = ["a", "b", "c"].map { root.appending(path: $0).path }.joined(separator: ":")
        let everywhere = ToolLocator(folders: [:], path: paths, versionOf: lookup)
        #expect(everywhere.find(.pgDump).map(\.versionString).prefix(2) == ["18.0", "16.2"])
        let (pg, warning) = everywhere.choose(.backupPostgres, serverMajor: 18, mariaDBServer: false)
        #expect(pg?.versionString == "18.0" && warning == nil)

        let chosen = ToolLocator(folders: [.postgres: root.appending(path: "a").path], path: paths, versionOf: lookup)
        #expect(chosen.find(.pgDump).map(\.versionString) == ["16.2"])
        let (old, oldWarning) = chosen.choose(.backupPostgres, serverMajor: 18, mariaDBServer: false)
        #expect(old?.versionString == "16.2")
        #expect(oldWarning?.contains("older than the server") == true)

        // Only MariaDB's mysqldump, for a MySQL server: used, with a warning.
        let (my, myWarning) = everywhere.choose(.backupMySQL, serverMajor: 8, mariaDBServer: false)
        #expect(my?.isMariaDB == true)
        #expect(myWarning != nil)
        #expect(everywhere.choose(.backupMySQL, serverMajor: 11, mariaDBServer: true).warning == nil)
    }

    private func tool(_ t: DumpTool, _ version: [Int], mariaDB: Bool = false) -> ToolInfo {
        ToolInfo(tool: t, path: "/x/\(t.rawValue)", versionText: "", version: version, isMariaDB: mariaDB)
    }

    @Test func postgresCommands() throws {
        var config = ConnectionConfig(name: "pg", driver: .postgres)
        config.user = "ann"
        config.tlsMode = .verifyFull
        config.tlsCAPath = "~/ca.pem"
        let login = BackupCommands.Login(config: config, password: "s3cret", endpoint: ToolEndpoint(host: "db.internal", port: 40000, hostAddress: "127.0.0.1"), database: "shop")
        var o = BackupOptions()
        o.postgresFormat = .plain
        o.gzip = true
        o.content = .schemaOnly
        o.noOwner = true
        o.clean = true
        o.otherArguments = "--exclude-table='a b'"
        let dump = try BackupCommands.pgDump(tool(.pgDump, [18, 1]), login, o, destination: URL(filePath: "/tmp/out.sql.gz"))
        #expect(dump.arguments == [
            "--host=db.internal", "--port=40000", "--username=ann", "--dbname=shop", "--no-password",
            "--format=plain", "--verbose", "--schema-only", "--no-owner", "--clean", "--if-exists", "--compress=6",
            "--exclude-table=a b", "--file=/tmp/out.sql.gz",
        ])
        #expect(dump.environment["PGPASSWORD"] == "s3cret")
        #expect(dump.environment["PGHOSTADDR"] == "127.0.0.1")
        #expect(dump.environment["PGSSLMODE"] == "verify-full")
        #expect(dump.environment["PGSSLROOTCERT"] == ("~/ca.pem" as NSString).expandingTildeInPath)
        #expect(!dump.display.contains("s3cret"))
        #expect(o.fileExtension(.postgres) == "sql.gz")

        var r = RestoreOptions()
        r.clean = true
        r.singleTransaction = true
        let restore = try BackupCommands.pgRestore(tool(.pgRestore, [18, 1]), login, r, source: URL(filePath: "/tmp/a.dump"))
        #expect(restore.arguments.suffix(5) == ["--clean", "--if-exists", "--single-transaction", "--exit-on-error", "/tmp/a.dump"])
        let script = try BackupCommands.psql(tool(.psql, [18, 1]), login, RestoreOptions(), source: URL(filePath: "/tmp/a.sql.gz"), gzipped: true)
        #expect(script.arguments.suffix(4) == ["--no-psqlrc", "--echo-errors", "--set=ON_ERROR_STOP=1", "--file=-"])
        if case .gunzip(let u) = script.input { #expect(u.path == "/tmp/a.sql.gz") } else { Issue.record("no gunzip input") }
    }

    @Test func mysqlCommandsKeepThePasswordInAPrivateFile() throws {
        var config = ConnectionConfig(name: "my", driver: .mysql)
        config.user = "bob"
        let folder = try BackupCommands.privateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let login = BackupCommands.Login(config: config, password: #"p"w\d"#, endpoint: ToolEndpoint(host: "h", port: 3306), database: "shop")
        var o = BackupOptions()
        o.gzip = true
        let dump = try BackupCommands.mysqldump(tool(.mysqldump, [9, 5, 0]), login, o, destination: URL(filePath: "/tmp/x.sql.gz"),
                                                folder: folder, serverIsMariaDB: true)
        let option = try #require(dump.secretFiles.first)
        #expect(dump.arguments.first == "--defaults-extra-file=\(option.path)")
        #expect(try String(contentsOf: option, encoding: .utf8) == "[client]\npassword=\"p\\\"w\\\\d\"\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: option.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        #expect(Array(dump.arguments[1...5]) == ["--protocol=tcp", "--host=h", "--port=3306", "--user=bob", "--ssl-mode=PREFERRED"])
        #expect(dump.arguments.contains("--column-statistics=0"))
        #expect(dump.arguments.contains("--set-gtid-purged=OFF"))
        #expect(dump.arguments.contains("--no-tablespaces"))
        #expect(dump.arguments.last == "shop")
        if case .gzip = dump.output {} else { Issue.record("not gzipped") }
        #expect(!dump.display.contains("p\"w"))

        let maria = try BackupCommands.mysqlRestore(tool(.mariadb, [11, 4], mariaDB: true), login, RestoreOptions(), source: URL(filePath: "/tmp/x.sql"),
                                                    gzipped: false, folder: folder)
        #expect(maria.arguments.contains("--ssl"))
        #expect(maria.arguments.contains("--skip-ssl-verify-server-cert"))
        #expect(!maria.arguments.contains("--force"))
    }

    @Test func fileKinds() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        func kind(_ data: Data) throws -> BackupFileKind {
            let url = dir.appending(path: UUID().uuidString)
            try data.write(to: url)
            return try BackupFileKind.detect(url)
        }
        #expect(try kind(Data("PGDMP\u{1}".utf8)) == .postgresArchive)
        #expect(try kind(Data([0x1F, 0x8B, 8])) == .sqlGzip)
        #expect(try kind(Data("CREATE TABLE".utf8)) == .sql)
        var tar = Data(count: 512)
        tar.replaceSubrange(257..<262, with: Data("ustar".utf8))
        #expect(try kind(tar) == .postgresTar)
        try FileManager.default.createDirectory(at: dir.appending(path: "d"), withIntermediateDirectories: true)
        #expect(throws: DatabaseError.self) { try BackupFileKind.detect(dir.appending(path: "d")) }
        FileManager.default.createFile(atPath: dir.appending(path: "d/toc.dat").path, contents: Data())
        #expect(try BackupFileKind.detect(dir.appending(path: "d")) == .postgresDirectory)
    }

    @Test func backupFileName() {
        var config = ConnectionConfig(name: "Prod", driver: .postgres)
        config.tag = .production
        var o = BackupOptions()
        o.postgresFormat = .directory
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        var job = BackupJob(config: config, password: nil, database: "a", options: o, tool: tool(.pgDump, [18]), serverIsMariaDB: false)
        #expect(job.fileName(FileNamePattern("{tag}-{database}"), date: when) == "production-a")
        job.options.postgresFormat = .custom
        #expect(job.fileName(FileNamePattern("{tag}-{database}"), date: when) == "production-a.dump")
        job.options.postgresFormat = .plain
        job.options.gzip = true
        #expect(job.fileName(FileNamePattern("{database}"), date: when) == "a.sql.gz")
    }

    @Test func optionsAsTokens() throws {
        var o = BackupOptions()
        #expect(o.tokens(.postgres) == [])
        #expect(o.tokens(.mysql) == ["--single-transaction", "--routines", "--triggers", "--add-drop-table"])
        try o.setTokens(["--clean", "--no-owner", "--exclude-table='a b'", "-n public", "--schema-only", "--format=d"], .postgres)
        #expect(o.clean && o.noOwner && !o.noPrivileges && !o.createDatabase)
        #expect(o.content == .schemaOnly)
        #expect(o.postgresFormat == .directory)
        #expect(o.otherArguments == "'--exclude-table=a b' -n public")
        #expect(o.tokens(.postgres) == ["--no-owner", "--clean", "'--exclude-table=a b'", "-n", "public"])
        // The same tokens read back give the same options.
        var again = o
        try again.setTokens(o.tokens(.postgres), .postgres)
        #expect(again == o)
        #expect(throws: DatabaseError.self) { try o.setTokens(["--exclude-table='a"], .postgres) }

        var my = BackupOptions()
        try my.setTokens(["--routines", "--databases", "--no-data", "--hex-blob"], .mysql)
        #expect(my.routines && my.createDatabase && !my.triggers && !my.singleTransaction && !my.addDropTable)
        #expect(my.content == .schemaOnly)
        #expect(my.otherArguments == "--hex-blob")

        var r = RestoreOptions()
        #expect(r.tokens(.postgres) == ["--exit-on-error"])
        #expect(r.tokens(.mysql) == [])
        try r.setTokens(["--force"], .mysql)
        #expect(!r.stopOnError)
        try r.setTokens(["--single-transaction", "--data-only"], .postgres)
        #expect(r.singleTransaction && !r.stopOnError && r.content == .dataOnly)
        #expect(ToolFlags.backupMenu(.postgres).starts(with: ["--no-owner", "--no-privileges", "--clean", "--create"]))
    }
}

struct ToolRunnerTests {
    private func system(_ path: String) -> ToolInfo {
        ToolInfo(tool: .psql, path: path, versionText: "", version: [], isMariaDB: false)
    }

    @Test func pipesGzipBothWays() async throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = String(repeating: "line ✓\n", count: 50_000)
        let plain = dir.appending(path: "in.txt")
        try Data(text.utf8).write(to: plain)
        // cat < in.txt | gzip > out.gz
        let zipped = dir.appending(path: "out.gz")
        var command = ToolCommand(tool: system("/bin/cat"), arguments: [], environment: [:])
        command.input = .file(plain)
        command.output = .gzip(zipped)
        try await ToolRunner.run(command) { _ in }
        #expect(try GzipReader.decompress(zipped) == Data(text.utf8))
        // gunzip < out.gz | cat > back.txt
        let back = dir.appending(path: "back.txt")
        command.input = .gunzip(zipped)
        command.output = .file(back)
        try await ToolRunner.run(command) { _ in }
        #expect(try Data(contentsOf: back) == Data(text.utf8))
        // Lines to the log.
        let lines = Lines()
        command.input = .file(plain)
        command.output = .log
        try await ToolRunner.run(command) { lines.add($0) }
        #expect(lines.all.count == 50_001)
        #expect(lines.all.first?.hasPrefix("$ /bin/cat < ") == true)
    }

    @Test func failureAndStop() async throws {
        let errors = Lines()
        do {
            try await ToolRunner.run(ToolCommand(tool: system("/bin/sh"), arguments: ["-c", "echo first >&2; echo why >&2; exit 3"], environment: [:])) { errors.add($0) }
            Issue.record("should have failed")
        } catch let error as DatabaseError {
            #expect(error.message == "psql failed (exit status 3): first\nwhy")
        }
        #expect(errors.all.suffix(2) == ["first", "why"])

        let started = Date()
        let task = Task { try await ToolRunner.run(ToolCommand(tool: system("/bin/sleep"), arguments: ["30"], environment: [:])) { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func secretFilesAreRemoved() async throws {
        let folder = try BackupCommands.privateFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = try BackupCommands.optionFile(password: "x", in: folder)
        var command = ToolCommand(tool: system("/usr/bin/true"), arguments: [], environment: [:])
        command.secretFiles = [secret]
        try await ToolRunner.run(command) { _ in }
        #expect(!FileManager.default.fileExists(atPath: secret.path))
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var all: [String] { lock.withLock { list } }
    func add(_ s: String) { lock.withLock { list.append(s) } }
}

/// Backup then restore into a new database with the tools installed on this Mac, against the
/// test servers. Skips what isn't installed.
@Suite(.serialized) struct BackupRoundTripTests {
    static let locator = ToolLocator()

    private struct Server {
        let config: ConnectionConfig
        let password: String?
        let admin: any DatabaseConnection
    }

    private func server(_ variable: String) async throws -> Server? {
        guard let text = ProcessInfo.processInfo.environment[variable], let (config, password) = ConnectionConfig.parse(url: text) else { return nil }
        var c = config
        if variable == "MOONROW_TEST_MARIADB" { c.driver = .mariadb }
        return Server(config: c, password: password, admin: try await ConnectionFactory.open(c, password: password))
    }

    private func open(_ s: Server, database: String) async throws -> any DatabaseConnection {
        var c = s.config
        c.database = database
        return try await ConnectionFactory.open(c, password: s.password)
    }

    private func seed(_ db: any DatabaseConnection) async throws {
        let pg = db.dialect is PostgresDialect
        for sql in [
            "CREATE TABLE parent (id \(pg ? "serial" : "int AUTO_INCREMENT") PRIMARY KEY, name varchar(40))",
            "CREATE TABLE child (id int PRIMARY KEY, parent_id int REFERENCES parent (id), note text)",
            "INSERT INTO parent (name) VALUES ('a'), ('it''s'), (NULL)",
            "INSERT INTO child VALUES (1, 1, 'tab\there'), (2, 2, 'é ✓')",
        ] { _ = try await db.execute(SQLStatement(sql)) }
    }

    private func contents(_ db: any DatabaseConnection) async throws -> [[DBValue]] {
        try await db.execute("SELECT id, name FROM parent ORDER BY id").rows + db.execute("SELECT id, parent_id, note FROM child ORDER BY id").rows
    }

    private func roundTrip(_ variable: String, _ variants: [(BackupOptions, RestoreOptions)]) async throws {
        guard let s = try await server(variable) else { return }
        let (major, maria) = ServerInfo.version(s.admin)
        let family: DumpTool.Family = s.config.driver == .postgres ? .postgres : .mysql
        let backupRole: ToolLocator.Role = family == .postgres ? .backupPostgres : .backupMySQL
        guard let dumpTool = Self.locator.choose(backupRole, serverMajor: major, mariaDBServer: maria).0 else { return }
        let source = "moonrow_bk_" + UUID().uuidString.prefix(6).lowercased()
        var created = [source]
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await s.admin.execute(SQLStatement(ServerInfo.createDatabase(source, dialect: s.admin.dialect)))
            let db = try await open(s, database: source)
            try await seed(db)
            let expected = try await contents(db)
            await db.close()
            #expect(try await ServerInfo.databases(s.admin).contains(source))

            for (i, (backup, restore)) in variants.enumerated() {
                let job = BackupJob(config: s.config, password: s.password, database: source, options: backup, tool: dumpTool,
                                    serverIsMariaDB: maria)
                let log = Lines()
                let file = dir.appending(path: job.fileName(FileNamePattern("{database}-\(i)")))
                try await job.run(to: file, log: { log.add($0) })
                #expect(log.all.first?.hasPrefix("$ ") == true)
                // The command line never carries the password (the test one, "moonrow", is also in
                // the database names, so look for the ways it could be passed).
                #expect(!log.all[0].contains("PGPASSWORD") && !log.all[0].contains("--password") && !log.all[0].contains(" -p"))
                let kind = try BackupFileKind.detect(file)
                #expect(kind == (family == .mysql ? (backup.gzip ? .sqlGzip : .sql) : backup.postgresFormat == .plain ? (backup.gzip ? .sqlGzip : .sql)
                        : backup.postgresFormat == .custom ? .postgresArchive : backup.postgresFormat == .tar ? .postgresTar : .postgresDirectory))
                // Nothing but the backup is left in the folder.
                #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }.isEmpty)

                let target = source + "_r\(i)"
                created.append(target)
                _ = try await s.admin.execute(SQLStatement(ServerInfo.createDatabase(target, dialect: s.admin.dialect)))
                let role = try #require(RestoreJob.role(for: kind, driver: s.config.driver))
                let restoreTool = try #require(Self.locator.choose(role, serverMajor: major, mariaDBServer: maria).0)
                try await RestoreJob(config: s.config, password: s.password, database: target, file: file, kind: kind,
                                     options: restore, tool: restoreTool).run { _ in }
                let restored = try await open(s, database: target)
                #expect(try await contents(restored) == expected, "variant \(i)")
                await restored.close()
            }
        } catch {
            for name in created { _ = try? await s.admin.execute(SQLStatement("DROP DATABASE IF EXISTS \(s.admin.dialect.quoteIdentifier(name))")) }
            await s.admin.close()
            throw error
        }
        for name in created { _ = try? await s.admin.execute(SQLStatement("DROP DATABASE IF EXISTS \(s.admin.dialect.quoteIdentifier(name))")) }
        await s.admin.close()
    }

    @Test func postgres() async throws {
        var custom = BackupOptions()
        custom.noOwner = true
        var plain = BackupOptions()
        plain.postgresFormat = .plain
        plain.gzip = true
        var directory = BackupOptions()
        directory.postgresFormat = .directory
        var single = RestoreOptions()
        single.singleTransaction = true
        try await roundTrip("MOONROW_TEST_PG", [(custom, RestoreOptions()), (plain, single), (directory, RestoreOptions())])
    }

    @Test func mysql() async throws {
        var gz = BackupOptions()
        gz.gzip = true
        try await roundTrip("MOONROW_TEST_MYSQL", [(BackupOptions(), RestoreOptions()), (gz, RestoreOptions())])
    }

    @Test func mariadb() async throws {
        var gz = BackupOptions()
        gz.gzip = true
        try await roundTrip("MOONROW_TEST_MARIADB", [(gz, RestoreOptions())])
    }

    @Test func failedBackupLeavesNoFile() async throws {
        guard let s = try await server("MOONROW_TEST_PG"),
              let tool = Self.locator.choose(.backupPostgres, serverMajor: 18, mariaDBServer: false).0 else { return }
        await s.admin.close()
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = BackupJob(config: s.config, password: s.password, database: "no_such_database_here", options: BackupOptions(),
                            tool: tool, serverIsMariaDB: false)
        do {
            try await job.run(to: dir.appending(path: "x.dump"), log: { _ in })
            Issue.record("should have failed")
        } catch let error as DatabaseError {
            #expect(error.message.contains("no_such_database_here"), "\(error.message)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
