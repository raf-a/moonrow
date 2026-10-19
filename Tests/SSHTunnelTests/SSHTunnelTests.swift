import AppCore
import DBKit
import DriverMySQL
import DriverPostgres
import DriverRemoteSQLite
import DriverSQLite
import Foundation
import Testing
import WireSupport
@testable import SSHTunnel

@Suite struct SSHPromptTests {
    @Test func classifiesOpenSSHPrompts() {
        #expect(SSHPrompt("moonrow@127.0.0.1's password: ") == .password(account: "moonrow@127.0.0.1"))
        #expect(SSHPrompt("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ")
            == .keyPassphrase(keyPath: "/Users/me/.ssh/id_ed25519"))
        let hostKey = """
            The authenticity of host '[127.0.0.1]:52222 ([127.0.0.1]:52222)' can't be established.
            ED25519 key fingerprint is: SHA256:ubyQPaa3ONsK0knbkW1/ZJ5X0HTi3+6l2u1wmzLYT4E
            This key is not known by any other names.
            Are you sure you want to continue connecting (yes/no/[fingerprint])?
            """
        let prompt = SSHPrompt(hostKey)
        guard case .hostKey = prompt else {
            Issue.record("not a host key prompt: \(prompt)")
            return
        }
        #expect(prompt.fingerprint == "SHA256:ubyQPaa3ONsK0knbkW1/ZJ5X0HTi3+6l2u1wmzLYT4E")
        #expect(!prompt.isSecret)
        #expect(SSHPrompt("Verification code: ") == .other(message: "Verification code:"))
        #expect(SSHPromptRequest(prompt: .other(message: "Code:"), isRetry: false, server: "x").offersSave == false)
        #expect(SSHPromptRequest(prompt: .password(account: "a@b"), isRetry: false, server: "x").offersSave)
    }

    @Test func masterArguments() {
        let c = SSHTunnelConfiguration(
            host: "-bastion", port: 2222, user: "deploy", identityFile: "/k/id",
            knownHostsFiles: ["/Users/me/Library/Application Support/Moonrow/known_hosts", "/Users/me/.ssh/known_hosts"],
            configFile: "none", useAgent: false, helperPath: "/x")
        let args = c.masterArguments(controlPath: "/tmp/t/m")
        #expect(args.prefix(9) == ["-F", "none", "-M", "-S", "/tmp/t/m", "-N", "-T", "-i", "/k/id"])
        #expect(args.contains(#"UserKnownHostsFile="/Users/me/Library/Application Support/Moonrow/known_hosts" /Users/me/.ssh/known_hosts"#))
        #expect(args.contains("IdentityAgent=none"))
        #expect(args.contains("IdentitiesOnly=yes"))
        #expect(args.contains("ClearAllForwardings=yes"))
        // A host that looks like an option can't be taken for one.
        #expect(args.suffix(6) == ["-p", "2222", "-l", "deploy", "--", "-bastion"])

        let plain = SSHTunnelConfiguration(host: "db", helperPath: "/x").masterArguments(controlPath: "/m")
        #expect(!plain.contains("-F") && !plain.contains("-p") && !plain.contains("-l") && !plain.contains("-i"))
        #expect(!plain.contains { $0.hasPrefix("UserKnownHostsFile") || $0.hasPrefix("IdentityAgent") })
    }

    @Test func streamArguments() {
        #expect(SSHTunnelConfiguration.streamArguments(controlPath: "/m", host: "::1", port: 5432).contains("[::1]:5432"))
        #expect(SSHTunnelConfiguration.streamArguments(controlPath: "/m", host: "db", port: 3306).contains("db:3306"))
    }

    /// The guard stops its child when the app's end of the lifeline closes (the app quit or
    /// crashed), and passes SIGTERM on.
    @Test func guardStopsItsChildWhenTheAppGoesAway() async throws {
        for viaSignal in [false, true] {
            let guardProcess = Process()
            guardProcess.executableURL = URL(filePath: SSHTestServer.helperPath)
            guardProcess.arguments = ["--guard", "/bin/sleep", "60"]
            let lifeline = Pipe()
            guardProcess.standardInput = lifeline
            try guardProcess.run()
            try await Task.sleep(for: .milliseconds(200))
            let sleeper = try SSHTestServer.child(of: guardProcess.processIdentifier)
            if viaSignal {
                guardProcess.terminate()
            } else {
                try lifeline.fileHandleForWriting.close()
            }
            let deadline = ContinuousClock.now + .seconds(4)
            while guardProcess.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(!guardProcess.isRunning)
            #expect(kill(sleeper, 0) != 0)
        }
    }

    @Test func cleansErrorOutput() {
        let errors = """
            Warning: Permanently added '[127.0.0.1]:52222' (ED25519) to the list of known hosts.
            ssh: connect to host nowhere port 22: Connection refused
            """
        #expect(SSHTunnel.cleaned(errors) == "connect to host nowhere port 22: Connection refused")
    }
}

@Suite struct SSHConfigTests {
    @Test func olderFilesLoadWithoutSSH() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","driver":"postgres","host":"db"}"#
        let c = try JSONDecoder().decode(ConnectionConfig.self, from: Data(json.utf8))
        #expect(!c.overSSH && !c.usesSSH && c.sshHost.isEmpty && c.sshPort == nil && c.sshPasswordMode == .keychain)
    }

    @Test func sshFieldsRoundTrip() throws {
        var c = ConnectionConfig(driver: .mysql, host: "10.0.0.5")
        let password = try c.applySSH(url: "ssh://deploy:s3cret@bastion.example:2200")
        #expect(password == "s3cret")
        #expect(c.usesSSH && c.sshHost == "bastion.example" && c.sshPort == 2200 && c.sshUser == "deploy")
        c.sshKeyPath = "~/.ssh/id_ed25519"
        let back = try JSONDecoder().decode(ConnectionConfig.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        #expect(c.summary.hasSuffix("via SSH deploy@bastion.example"))
        #expect(throws: DatabaseError.self) { try c.applySSH(url: "postgres://x") }
        // A SQLite file over SSH is a path on the server, kept as typed for the server to expand.
        let remote = ConnectionConfig(driver: .sqlite, filePath: "~/data/app.db", overSSH: true, sshHost: "bastion", sshUser: "deploy")
        #expect(remote.usesSSH && remote.expandedFilePath == "~/data/app.db" && remote.remoteSQLiteCommand == "sqlite3")
        #expect(remote.summary == "SQLite · ~/data/app.db · on deploy@bastion")
    }

    @Test func tunnelConfigurationFollowsPasswordMode() throws {
        var c = ConnectionConfig(driver: .postgres, host: "db", sshHost: " bastion ", sshUser: "u", sshKeyPath: "~/k")
        c.overSSH = true
        let login = SSHLogin(password: "pw", keyPassphrase: "kp")
        var t = try ConnectionFactory.tunnelConfiguration(c, login)
        #expect(t.host == "bastion" && t.password == "pw" && t.keyPassphrase == "kp")
        #expect(t.identityFile == ("~/k" as NSString).expandingTildeInPath)
        c.sshPasswordMode = .none
        t = try ConnectionFactory.tunnelConfiguration(c, login)
        #expect(t.password == nil)
        c.sshHost = ""
        #expect(throws: DatabaseError.self) { try ConnectionFactory.tunnelConfiguration(c, login) }
    }

    @Test func secretKindsAreSeparate() throws {
        let store = MemorySecretStore()
        let id = UUID(), copy = UUID()
        try store.setPassword("db", for: id)
        try store.setSecret("ssh", .sshPassword, for: id)
        try store.setSecret("phrase", .sshKeyPassphrase, for: id)
        #expect(try store.password(for: id) == "db")
        store.copyAll(from: id, to: copy)
        #expect(try store.secret(.sshPassword, for: copy) == "ssh")
        #expect(try store.secret(.sshKeyPassphrase, for: copy) == "phrase")
        store.removeAll(for: id)
        #expect(try SecretKind.allCases.allSatisfy { try store.secret($0, for: id) == nil })
        #expect(try store.password(for: copy) == "db")
    }

    @Test func fileSecretsKeepTheirOldKeys() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "secrets-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        try Data(#"{"\#(id.uuidString)":"old"}"#.utf8).write(to: url)
        let store = FileSecretStore(url: url)
        #expect(try store.password(for: id) == "old")
        #expect(try store.secret(.sshPassword, for: id) == nil)
    }

    @Test func socketsCantGoOverSSH() async {
        var c = ConnectionConfig(driver: .postgres, host: "/tmp/.s.PGSQL.5432", sshHost: "bastion")
        c.overSSH = true
        await #expect(throws: DatabaseError.self) { try await ConnectionFactory.open(c) }
    }
}

// MARK: - Against the test servers

/// `MOONROW_TEST_SSH` (`ssh://moonrow:moonrow@127.0.0.1:52222`) from `scripts/test-servers.sh env`;
/// the databases are reached from there by container name.
enum SSHTestServer {
    static let url = ProcessInfo.processInfo.environment["MOONROW_TEST_SSH"].flatMap { URLComponents(string: $0) }
    static let pg = ProcessInfo.processInfo.environment["MOONROW_TEST_PG"].flatMap { URLComponents(string: $0) }
    static let mysql = ProcessInfo.processInfo.environment["MOONROW_TEST_MYSQL"].flatMap { URLComponents(string: $0) }
    static var isAvailable: Bool { url != nil && pg != nil }

    /// The helper `swift test` builds next to the test bundle.
    static var helperPath: String {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let path = URL(filePath: bundle.bundlePath).deletingLastPathComponent().appending(path: "moonrow-ssh-helper").path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appending(path: ".build/debug/moonrow-ssh-helper").path
    }

    /// A copy of a test key with the permissions ssh insists on.
    static func key(_ name: String, in directory: URL) throws -> String {
        let source = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)")
        let target = directory.appending(path: name)
        try FileManager.default.copyItem(at: source, to: target)
        chmod(target.path, 0o600)
        return target.path
    }

    /// Never the user's ~/.ssh: no config, no agent, a fresh known_hosts.
    static func configuration(
        directory: URL, password: String? = nil, identityFile: String? = nil, keyPassphrase: String? = nil
    ) -> SSHTunnelConfiguration {
        SSHTunnelConfiguration(
            host: url!.host!, port: url!.port, user: url!.user!, identityFile: identityFile,
            password: password, keyPassphrase: keyPassphrase,
            knownHostsFiles: [directory.appending(path: "known_hosts").path],
            configFile: "none", useAgent: false, helperPath: helperPath, connectTimeout: 5)
    }

    static func postgres(through tunnel: SSHTunnel, tls: TLSMode = .disable) -> PostgresConfiguration {
        PostgresConfiguration(
            endpoint: tunnel.endpoint(host: "moonrow-test-pg", port: 5432), user: pg!.user!, password: pg!.password,
            database: String(pg!.path.dropFirst()), tls: TLSSettings(mode: tls), connectTimeout: 5)
    }

    /// The ssh a guard process runs (killing it simulates a dropped connection).
    static func child(of pid: pid_t) throws -> pid_t {
        let pgrep = Process()
        pgrep.executableURL = URL(filePath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let out = Pipe()
        pgrep.standardOutput = out
        try pgrep.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        pgrep.waitUntilExit()
        return try #require(pid_t(text.split(separator: "\n").first ?? ""))
    }

    /// ssh processes on this machine using one of our control sockets.
    static func tunnelProcessCount() throws -> Int {
        let ps = Process()
        ps.executableURL = URL(filePath: "/bin/ps")
        ps.arguments = ["-axo", "command"]
        let out = Pipe()
        ps.standardOutput = out
        try ps.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return text.split(separator: "\n").filter { $0.contains("ssh") && $0.contains("/tmp/moonrow-ssh.") }.count
    }
}

/// Records prompts and answers them from a script.
final class PromptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [SSHPromptRequest] = []
    private let reply: @Sendable (SSHPromptRequest) -> SSHAnswer?

    init(_ reply: @escaping @Sendable (SSHPromptRequest) -> SSHAnswer?) {
        self.reply = reply
    }

    var seen: [SSHPromptRequest] { lock.withLock { requests } }

    var responder: SSHPromptResponder {
        { request in
            self.lock.withLock { self.requests.append(request) }
            return self.reply(request)
        }
    }

    /// Trusts host keys and answers nothing else.
    static func trustingHostKeys() -> PromptLog {
        PromptLog { request in
            if case .hostKey = request.prompt { return SSHAnswer("yes") }
            return nil
        }
    }
}

@Suite(.enabled(if: SSHTestServer.isAvailable), .serialized)
struct SSHTunnelServerTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ssh-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test func passwordLoginAsksOnceAboutTheHostKey() async throws {
        let log = PromptLog.trustingHostKeys()
        let tunnel = try SSHTunnel(
            SSHTestServer.configuration(directory: directory, password: SSHTestServer.url!.password), responder: log.responder)
        let db = try await PostgresConnection.connect(SSHTestServer.postgres(through: tunnel))
        let result = try await db.execute("SELECT inet_server_port(), 1 + 1")
        #expect(result.rows.first?.last == .integer(2))
        await db.close()
        await tunnel.close()
        #expect(log.seen.count == 1)
        #expect(log.seen.first?.prompt.fingerprint?.hasPrefix("SHA256:") == true)
        let knownHosts = try String(contentsOf: directory.appending(path: "known_hosts"), encoding: .utf8)
        #expect(knownHosts.contains("[127.0.0.1]:52222"))

        // Known now: no more questions.
        let again = PromptLog.trustingHostKeys()
        let second = try SSHTunnel(
            SSHTestServer.configuration(directory: directory, password: SSHTestServer.url!.password), responder: again.responder)
        try await second.connect()
        await second.close()
        #expect(again.seen.isEmpty)
    }

    @Test func rejectedHostKeyFailsTheLogin() async throws {
        let tunnel = try SSHTunnel(
            SSHTestServer.configuration(directory: directory, password: SSHTestServer.url!.password),
            responder: { _ in nil })
        await #expect {
            try await tunnel.connect()
        } throws: { error in
            "\(error)".contains("Host key verification failed")
        }
        await tunnel.close()
    }

    @Test func wrongSavedPasswordAsksTheUser() async throws {
        let right = SSHTestServer.url!.password!
        let log = PromptLog { request in
            switch request.prompt {
            case .hostKey: SSHAnswer("yes")
            case .password: SSHAnswer(right, save: true)
            default: nil
            }
        }
        let saved = SavedLog()
        let tunnel = try SSHTunnel(
            SSHTestServer.configuration(directory: directory, password: "wrong"), responder: log.responder,
            onSave: saved.record)
        try await tunnel.connect()
        let passwordPrompts = log.seen.filter { if case .password = $0.prompt { true } else { false } }
        #expect(passwordPrompts.count == 1 && passwordPrompts[0].isRetry)
        #expect(saved.values == [.password: right])

        // A dropped connection logs in again with the password that worked, without asking.
        let pid = try #require(await tunnel.masterProcessID)
        kill(try SSHTestServer.child(of: pid), SIGKILL)
        try await Task.sleep(for: .milliseconds(200))
        try await tunnel.connect()
        #expect(log.seen.filter { if case .password = $0.prompt { true } else { false } }.count == 1)
        #expect(await tunnel.masterProcessID != pid)
        await tunnel.close()
    }

    @Test(arguments: ["test_ed25519", "test_rsa"])
    func keyLogin(_ name: String) async throws {
        let key = try SSHTestServer.key(name, in: directory)
        let log = PromptLog.trustingHostKeys()
        let tunnel = try SSHTunnel(SSHTestServer.configuration(directory: directory, identityFile: key), responder: log.responder)
        try await tunnel.connect()
        await tunnel.close()
        #expect(log.seen.allSatisfy { if case .hostKey = $0.prompt { true } else { false } })
    }

    @Test func encryptedKeyAsksForThePassphrase() async throws {
        let key = try SSHTestServer.key("test_ed25519_encrypted", in: directory)
        let log = PromptLog { request in
            switch request.prompt {
            case .hostKey: SSHAnswer("yes")
            case .keyPassphrase: SSHAnswer("secret phrase", save: true)
            default: nil
            }
        }
        let saved = SavedLog()
        let tunnel = try SSHTunnel(
            SSHTestServer.configuration(directory: directory, identityFile: key), responder: log.responder,
            onSave: saved.record)
        try await tunnel.connect()
        await tunnel.close()
        #expect(log.seen.contains { $0.prompt == .keyPassphrase(keyPath: key) })
        #expect(saved.values == [.keyPassphrase: "secret phrase"])
    }

    @Test func postgresOverTLSAndCancelThroughTheTunnel() async throws {
        let tunnel = try SSHTunnel(
            SSHTestServer.configuration(directory: directory, password: SSHTestServer.url!.password),
            responder: PromptLog.trustingHostKeys().responder)
        let db = try await PostgresConnection.connect(SSHTestServer.postgres(through: tunnel, tls: .require))
        let ssl = try await db.execute("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
        #expect(ssl.rows.first?.first == .bool(true))

        // The cancel request is one more stream through the tunnel.
        let started = ContinuousClock.now
        let sleeper = Task { try await db.execute("SELECT pg_sleep(30)") }
        try await Task.sleep(for: .milliseconds(300))
        sleeper.cancel()
        _ = await sleeper.result
        #expect(ContinuousClock.now - started < .seconds(5))
        let after = try await db.execute("SELECT 42")
        #expect(after.rows.first?.first == .integer(42))
        await db.close()
        await tunnel.close()
    }

    @Test func mysqlThroughTheTunnel() async throws {
        let mysql = try #require(SSHTestServer.mysql)
        let tunnel = try SSHTunnel(
            SSHTestServer.configuration(directory: directory, password: SSHTestServer.url!.password),
            responder: PromptLog.trustingHostKeys().responder)
        let db = try await MySQLConnection.connect(MySQLConfiguration(
            endpoint: tunnel.endpoint(host: "moonrow-test-mysql", port: 3306), user: mysql.user!,
            password: mysql.password!, database: "moonrow", tls: TLSSettings(mode: .require), connectTimeout: 5))
        let result = try await db.execute("SELECT @@hostname IS NOT NULL, 6 * 7")
        #expect(result.rows.first?.last == .integer(42))
        await db.close()
        await tunnel.close()
    }

    @Test func droppedTunnelHealsOnTheNextStatement() async throws {
        let tunnel = try SSHTunnel(
            SSHTestServer.configuration(directory: directory, password: SSHTestServer.url!.password),
            responder: PromptLog.trustingHostKeys().responder)
        let db = try await PostgresConnection.connect(SSHTestServer.postgres(through: tunnel))
        _ = try await db.execute("SELECT 1")
        let pid = try #require(await tunnel.masterProcessID)
        kill(try SSHTestServer.child(of: pid), SIGKILL)
        // The stream ends with the master; the session notices before the next statement.
        try await Task.sleep(for: .milliseconds(500))
        let result = try await db.execute("SELECT 7")
        #expect(result.rows.first?.first == .integer(7))
        #expect(await tunnel.masterProcessID != pid)
        await db.close()
        await tunnel.close()
    }

    @Test func unreachableDatabaseSaysWhy() async throws {
        let tunnel = try SSHTunnel(
            SSHTestServer.configuration(directory: directory, password: SSHTestServer.url!.password),
            responder: PromptLog.trustingHostKeys().responder)
        var c = SSHTestServer.postgres(through: tunnel)
        c.endpoint = tunnel.endpoint(host: "no-such-host.invalid", port: 5432)
        await #expect {
            _ = try await PostgresConnection.connect(c)
        } throws: { error in
            "\(error)".contains("forwarding") || "\(error)".contains("refused")
        }
        await tunnel.close()
    }

    @Test func closingStopsEveryProcess() async throws {
        let before = try SSHTestServer.tunnelProcessCount()
        let tunnel = try SSHTunnel(
            SSHTestServer.configuration(directory: directory, password: SSHTestServer.url!.password),
            responder: PromptLog.trustingHostKeys().responder)
        let db = try await PostgresConnection.connect(SSHTestServer.postgres(through: tunnel))
        _ = try await db.execute("SELECT 1")
        #expect(await tunnel.runningProcessIDs.count >= 2)
        await db.close()
        await tunnel.close()
        #expect(await tunnel.runningProcessIDs.isEmpty)
        #expect(try SSHTestServer.tunnelProcessCount() == before)
    }

    @Test func factoryConnectionEndsItsTunnelWhenReleased() async throws {
        let before = try SSHTestServer.tunnelProcessCount()
        let pg = SSHTestServer.pg!, ssh = SSHTestServer.url!
        var config = ConnectionConfig(
            driver: .postgres, host: "moonrow-test-pg", port: 5432, user: pg.user!, database: String(pg.path.dropFirst()),
            tlsMode: .disable, overSSH: true, sshHost: ssh.host!, sshPort: ssh.port, sshUser: ssh.user!)
        config.sshPasswordMode = .keychain
        let login = SSHLogin(
            password: ssh.password, responder: PromptLog.trustingHostKeys().responder,
            knownHostsFiles: [directory.appending(path: "known_hosts").path], configFile: "none", useAgent: false,
            helperPath: SSHTestServer.helperPath)
        try await ConnectionFactory.test(config, password: pg.password, ssh: login)
        // Released with the connection; give the processes a moment to exit.
        let deadline = ContinuousClock.now + .seconds(4)
        while try SSHTestServer.tunnelProcessCount() != before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try SSHTestServer.tunnelProcessCount() == before)
    }

    /// pg_dump and mysqldump reach the databases by container name through a local port the
    /// tunnel carries; the port and the ssh processes go away afterwards.
    @Test func backupThroughTheTunnel() async throws {
        let before = try SSHTestServer.tunnelProcessCount()
        let ssh = SSHTestServer.url!
        let login = SSHLogin(
            password: ssh.password, responder: PromptLog.trustingHostKeys().responder,
            knownHostsFiles: [directory.appending(path: "known_hosts").path], configFile: "none", useAgent: false,
            helperPath: SSHTestServer.helperPath)
        // The bundled tools: MOONROW_TOOLS, else this checkout's build/tools.
        let checkout = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tools = BundledTools(folder: ProcessInfo.processInfo.environment["MOONROW_TOOLS"].map { URL(filePath: $0) }
            ?? checkout.appending(path: "build/tools"))
        var targets: [(ConnectionConfig, String?, BundledTools.Role)] = []
        if let pg = SSHTestServer.pg {
            var c = ConnectionConfig(driver: .postgres, host: "moonrow-test-pg", port: 5432, user: pg.user!, database: String(pg.path.dropFirst()),
                                     tlsMode: .require, overSSH: true, sshHost: ssh.host!, sshPort: ssh.port, sshUser: ssh.user!)
            c.sshPasswordMode = .keychain
            targets.append((c, pg.password, .backupPostgres))
        }
        if let my = SSHTestServer.mysql {
            var c = ConnectionConfig(driver: .mysql, host: "moonrow-test-mysql", port: 3306, user: my.user!, database: String(my.path.dropFirst()),
                                     overSSH: true, sshHost: ssh.host!, sshPort: ssh.port, sshUser: ssh.user!)
            c.sshPasswordMode = .keychain
            targets.append((c, my.password, .backupMySQL))
        }
        for (config, password, role) in targets {
            guard let tool = tools.choose(role, serverMajor: nil, mariaDBServer: false).0 else { continue }
            var options = BackupOptions()
            options.content = .schemaOnly
            let job = BackupJob(config: config, password: password, ssh: login, database: config.database, options: options,
                                tool: tool, serverIsMariaDB: false)
            let lines = LockedLines()
            let file = directory.appending(path: job.fileName(FileNamePattern("{database}")))
            try await job.run(to: file, log: { lines.add($0) })
            let head = try FileHandle(forReadingFrom: file).read(upToCount: 64) ?? Data()
            if role == .backupPostgres {
                #expect(head.starts(with: Data("PGDMP".utf8)))
                #expect(lines.all.first?.contains("--host=moonrow-test-pg") == true)
            } else {
                #expect(String(decoding: head, as: UTF8.self).contains("dump"))
                #expect(lines.all.first?.contains("--host=127.0.0.1") == true)
            }
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while try SSHTestServer.tunnelProcessCount() != before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try SSHTestServer.tunnelProcessCount() == before)
    }
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var all: [String] { lock.withLock { list } }
    func add(_ s: String) { lock.withLock { list.append(s) } }
}

final class SavedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [SSHSecret: String] = [:]
    var values: [SSHSecret: String] { lock.withLock { saved } }
    var record: @Sendable (SSHSecret, String) -> Void {
        { secret, value in self.lock.withLock { self.saved[secret] = value } }
    }
}

/// SQLite files on the SSH server: its own sqlite3 on the live file, or a copy when it has none.
/// In the same serialized suite as the other tunnel tests, which count ssh processes.
extension SSHTunnelServerTests {
    private var sqliteLogin: SSHLogin {
        SSHLogin(
            password: SSHTestServer.url!.password, responder: PromptLog.trustingHostKeys().responder,
            knownHostsFiles: [directory.appending(path: "known_hosts").path], configFile: "none", useAgent: false,
            helperPath: SSHTestServer.helperPath)
    }

    private func sqliteConfig(_ path: String, sqlite3: String = "") -> ConnectionConfig {
        let ssh = SSHTestServer.url!
        var c = ConnectionConfig(driver: .sqlite, filePath: path, passwordMode: .none, overSSH: true,
                                 sshHost: ssh.host!, sshPort: ssh.port, sshUser: ssh.user!)
        c.sshPasswordMode = .keychain
        c.sqliteCommand = sqlite3
        return c
    }

    /// Runs `sql` on the server with its sqlite3, as another program would.
    private func onServer(_ path: String, _ sql: String) async throws -> String {
        let tunnel = try SSHTunnel(SSHTestServer.configuration(directory: directory, password: SSHTestServer.url!.password),
                                   responder: PromptLog.trustingHostKeys().responder)
        defer { Task { await tunnel.close() } }
        let out = try await tunnel.run("sqlite3 \(SSHTunnelConfiguration.shellQuoted(path)) \(SSHTunnelConfiguration.shellQuoted(sql))")
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a test file (and its -wal and -shm) from the server.
    private func remove(_ path: String) async {
        guard let tunnel = try? SSHTunnel(SSHTestServer.configuration(directory: directory, password: SSHTestServer.url!.password),
                                          responder: PromptLog.trustingHostKeys().responder) else { return }
        let q = SSHTunnelConfiguration.shellQuoted(path)
        _ = try? await tunnel.run("rm -f \(q) \(q)-wal \(q)-shm")
        await tunnel.close()
    }

    @Test func liveFileThroughTheServersSQLite() async throws {
        let before = try SSHTestServer.tunnelProcessCount()
        let path = "/tmp/moonrow-m12-\(UUID().uuidString.prefix(8)).sqlite"
        _ = try await onServer(path, "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes (body) VALUES ('one');")
        do {
            let db = try await ConnectionFactory.open(sqliteConfig(path), ssh: sqliteLogin)
            #expect((db as? RemoteSQLiteConnection)?.sqliteVersion.hasPrefix("3.") == true)
            #expect(try await db.objects(schema: nil).map(\.ref.name) == ["notes"])
            #expect(try await db.execute("SELECT body FROM notes").rows == [[.text("one")]])
            #expect(try await db.execute(SQLStatement("INSERT INTO notes (body) VALUES (?)", bindings: [.text("it's two")])).rowsAffected == 1)
            // Another program on the server sees the write, and we see its.
            #expect(try await onServer(path, "SELECT body FROM notes WHERE id = 2") == "it's two")
            _ = try await onServer(path, "INSERT INTO notes (body) VALUES ('three')")
            #expect(try await db.execute("SELECT count(*) FROM notes").rows.first?.first == .integer(3))
            // Stopping a long statement interrupts it on the server; the next one gets a new sqlite3.
            let endless = Task { try await db.execute("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n") }
            try await Task.sleep(for: .milliseconds(500))
            let clock = ContinuousClock(), start = clock.now
            endless.cancel()
            _ = await endless.result
            #expect(clock.now - start < .seconds(5))
            #expect(try await db.execute("SELECT count(*) FROM notes").rows.first?.first == .integer(3))
            await db.close()
        }
        #expect(try await onServer(path, "PRAGMA integrity_check") == "ok")
        await remove(path)
        let deadline = ContinuousClock.now + .seconds(4)
        while try SSHTestServer.tunnelProcessCount() != before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try SSHTestServer.tunnelProcessCount() == before)
    }

    @Test func remoteSQLiteMissingFileOrSQLite() async throws {
        do {
            _ = try await ConnectionFactory.open(sqliteConfig("/tmp/moonrow-no-such-file.sqlite"), ssh: sqliteLogin)
            Issue.record("opened a missing file")
        } catch let e as RemoteSQLiteError {
            #expect(e.description == "There is no file at /tmp/moonrow-no-such-file.sqlite on the server.")
        }
        let path = "/tmp/moonrow-m12-\(UUID().uuidString.prefix(8)).sqlite"
        _ = try await onServer(path, "CREATE TABLE t (x); INSERT INTO t VALUES (1);")
        do {
            _ = try await ConnectionFactory.open(sqliteConfig(path, sqlite3: "moonrow-sqlite3-missing"), ssh: sqliteLogin)
            Issue.record("opened without sqlite3")
        } catch let e as RemoteSQLiteError {
            #expect(e.description == "The server has no moonrow-sqlite3-missing.")
        }
        await remove(path)
    }

    /// Without sqlite3 on the server: a copy, edited here only.
    @Test func copyWhenTheServerHasNoSQLite() async throws {
        let path = "/tmp/moonrow-m12-\(UUID().uuidString.prefix(8)).sqlite"
        _ = try await onServer(path, "PRAGMA journal_mode = WAL; CREATE TABLE t (x); INSERT INTO t VALUES (1), (2);")
        let db = try await ConnectionFactory.open(sqliteConfig(path, sqlite3: "moonrow-sqlite3-missing"), ssh: sqliteLogin, remoteCopy: true)
        let sqlite = try #require(db as? SQLiteConnection)
        #expect(await sqlite.copyOf?.hasSuffix(":" + path) == true)
        #expect(try await db.execute("SELECT count(*) FROM t").rows.first?.first == .integer(2))
        _ = try await db.execute("DELETE FROM t")
        #expect(try await onServer(path, "SELECT count(*) FROM t") == "2")
        let folder = URL(filePath: sqlite.path).deletingLastPathComponent()
        await db.close()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await remove(path)
    }
}
