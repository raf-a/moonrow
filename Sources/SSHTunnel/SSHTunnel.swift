import DBKit
import Darwin
import Foundation
import WireSupport

public struct SSHTunnelError: Error, Sendable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

public struct SSHTunnelConfiguration: Sendable, Hashable {
    /// The SSH server, as ssh would be given it (a ~/.ssh/config alias works too).
    public var host: String
    /// Nil leaves it to ssh (its config, else 22).
    public var port: Int?
    /// Empty leaves it to ssh (its config, else the login name).
    public var user: String
    /// A private key file; nil lets ssh pick (its config, the agent, the default key files).
    public var identityFile: String?
    /// Answers the first password / key passphrase prompt without asking.
    public var password: String?
    public var keyPassphrase: String?
    /// Known-hosts files, the first one getting newly accepted keys. Empty leaves it to ssh.
    public var knownHostsFiles: [String]
    /// The ssh config file; nil reads the user's, "none" reads none (tests).
    public var configFile: String?
    /// False keeps ssh away from the agent (tests).
    public var useAgent: Bool
    public var sshPath: String
    /// The SSH_ASKPASS helper (`moonrow-ssh-helper`).
    public var helperPath: String
    public var connectTimeout: Int
    /// Seconds between keepalive probes; the tunnel drops after 3 unanswered ones.
    public var keepAliveInterval: Int

    public init(
        host: String, port: Int? = nil, user: String = "", identityFile: String? = nil,
        password: String? = nil, keyPassphrase: String? = nil, knownHostsFiles: [String] = [],
        configFile: String? = nil, useAgent: Bool = true, sshPath: String = "/usr/bin/ssh",
        helperPath: String = SSHTunnel.defaultHelperPath, connectTimeout: Int = 15, keepAliveInterval: Int = 30
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.password = password
        self.keyPassphrase = keyPassphrase
        self.knownHostsFiles = knownHostsFiles
        self.configFile = configFile
        self.useAgent = useAgent
        self.sshPath = sshPath
        self.helperPath = helperPath
        self.connectTimeout = connectTimeout
        self.keepAliveInterval = keepAliveInterval
    }

    /// `user@host:port` as far as we know it.
    public var server: String {
        var s = user.isEmpty ? host : "\(user)@\(host)"
        if let port { s += ":\(port)" }
        return s
    }

    /// Arguments for the master: logs in, then just holds the connection for the mux clients.
    func masterArguments(controlPath: String) -> [String] {
        var args: [String] = []
        if let configFile { args += ["-F", configFile] }
        args += ["-M", "-S", controlPath, "-N", "-T"]
        var options = [
            "ControlPersist=no",
            "ServerAliveInterval=\(keepAliveInterval)", "ServerAliveCountMax=3",
            "ConnectTimeout=\(connectTimeout)",
            "BatchMode=no",
            "ExitOnForwardFailure=yes",
            // Forwards or a remote command from the user's config have no business here; a busy
            // LocalForward port would even fail the login.
            "ClearAllForwardings=yes", "RemoteCommand=none", "RequestTTY=no", "PermitLocalCommand=no",
        ]
        if !knownHostsFiles.isEmpty {
            options.append("UserKnownHostsFile=" + knownHostsFiles.map(Self.configQuoted).joined(separator: " "))
        }
        if !useAgent { options.append("IdentityAgent=none") }
        if let identityFile {
            args += ["-i", identityFile]
            options.append("IdentitiesOnly=yes")
        }
        for o in options { args += ["-o", o] }
        if let port { args += ["-p", String(port)] }
        if !user.isEmpty { args += ["-l", user] }
        return args + ["--", host]
    }

    /// Arguments for one stream: a mux client asking the master for a channel to `host:port`.
    /// It never logs in on its own: no config, no agent, and a proxy that fails if the master
    /// is gone.
    static func streamArguments(controlPath: String, host: String, port: Int) -> [String] {
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        return ["-F", "none", "-S", controlPath, "-o", "ControlMaster=no", "-o", "BatchMode=yes",
                "-o", "ProxyCommand=/usr/bin/false", "-W", target, "moonrow-tunnel"]
    }

    /// ssh_config quoting for a value that may hold spaces (Application Support).
    static func configQuoted(_ s: String) -> String {
        s.contains(where: { $0 == " " || $0 == "\"" }) ? "\"\(s.replacingOccurrences(of: "\"", with: ""))\"" : s
    }
}

/// An SSH connection that carries database sockets, made with the system's OpenSSH client.
///
/// A master process (`ssh -M -N`) logs in once and keeps the connection; each database socket
/// is a mux client (`ssh -W host:port`) whose stdin/stdout is one end of a socket pair. Nothing
/// listens on a local port. Prompts (passwords, passphrases, unknown host keys) come back
/// through SSH_ASKPASS to `responder`. If the master dies (network drop, keepalive timeout), the
/// next socket opened logs in again.
public actor SSHTunnel {
    public nonisolated let configuration: SSHTunnelConfiguration
    private let responder: SSHPromptResponder?
    private let onSave: (@Sendable (SSHSecret, String) -> Void)?
    private let directory: String
    private nonisolated var controlPath: String { directory + "/m" }

    private var master: Subprocess?
    private var starting: Task<Void, any Error>?
    private var askpass: AskpassServer?
    private var isClosed = false
    // What answered prompts so far; answers typed in a login become these once it works.
    private var password: String?
    private var keyPassphrase: String?
    // The current login's prompts.
    private var asked: Set<String> = []
    private var typed: [SSHSecret: SSHAnswer] = [:]
    private var streams: [Subprocess] = []

    /// `responder` asks the user (nil: every unanswered prompt cancels the login); `onSave`
    /// receives answers the user asked to keep, once the login they were typed into worked.
    public init(
        _ configuration: SSHTunnelConfiguration, responder: SSHPromptResponder? = nil,
        onSave: (@Sendable (SSHSecret, String) -> Void)? = nil
    ) throws {
        self.configuration = configuration
        self.responder = responder
        self.onSave = onSave
        password = configuration.password
        keyPassphrase = configuration.keyPassphrase
        // Short, private and ours: the control socket path must fit in sun_path (104 bytes).
        var template = Array("/tmp/moonrow-ssh.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else {
            throw SSHTunnelError("Can't create a folder for the SSH tunnel: \(String(cString: strerror(errno)))")
        }
        directory = String(cString: made)
    }

    deinit {
        master?.signal(SIGTERM)
        for s in streams { s.signal(SIGTERM) }
        askpass?.close()
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// The default helper: `moonrow-ssh-helper` next to the running executable (inside the app
    /// bundle, or the build folder).
    public static var defaultHelperPath: String {
        let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appending(path: "moonrow-ssh-helper").path
    }

    /// An endpoint for the drivers: every socket they open to it is a new channel through this
    /// tunnel to `host:port`, as the SSH server resolves it.
    public nonisolated func endpoint(host: String, port: Int) -> Endpoint {
        let place = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let opener = StreamOpener(description: "\(place) via SSH \(configuration.server)", hostName: host) {
            try await self.openStream(host: host, port: port)
        }
        return .stream(opener)
    }

    /// A socket carried to `host:port`.
    public func openStream(host: String, port: Int) async throws -> OpenedStream {
        try await connect()
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw SSHTunnelError("Can't create a socket for the SSH tunnel: \(String(cString: strerror(errno)))")
        }
        let process: Subprocess
        do {
            process = try Subprocess(
                configuration.sshPath,
                SSHTunnelConfiguration.streamArguments(controlPath: controlPath, host: host, port: port),
                environment: baseEnvironment, stdio: pair[1])
        } catch {
            Darwin.close(pair[0])
            Darwin.close(pair[1])
            throw error
        }
        Darwin.close(pair[1])
        streams.removeAll { !$0.isRunning }
        streams.append(process)
        return OpenedStream(descriptor: pair[0]) {
            // The pipe closed: give ssh a moment to exit and say why.
            _ = await process.waitForExit(timeout: .seconds(2))
            return Self.cleaned(process.errors)
        }
    }

    /// Carries an accepted socket to `host:port`: a mux client gets it as stdin and stdout, and
    /// our copy is closed. For `LocalForward`.
    func carry(_ descriptor: Int32, host: String, port: Int) async {
        do {
            try await connect()
            let process = try Subprocess(
                configuration.sshPath,
                SSHTunnelConfiguration.streamArguments(controlPath: controlPath, host: host, port: port),
                environment: baseEnvironment, stdio: descriptor)
            streams.removeAll { !$0.isRunning }
            streams.append(process)
        } catch {
            // The client sees its connection close.
        }
        Darwin.close(descriptor)
    }

    /// Logs in unless the master is up already.
    public func connect() async throws {
        if isClosed { throw SSHTunnelError("The SSH tunnel is closed.") }
        if let starting { return try await starting.value }
        if let master, master.isRunning, isSocket(controlPath) { return }
        let task = Task { try await startMaster() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    /// Whether the master is up (for tests and status).
    public var isConnected: Bool {
        guard let master else { return false }
        return master.isRunning && isSocket(controlPath)
    }

    /// The master's guard process (`moonrow-ssh-helper --guard`; ssh is its child) while it runs.
    public var masterProcessID: pid_t? { master?.isRunning == true ? master?.pid : nil }

    /// Process ids of everything this tunnel started that's still running.
    public var runningProcessIDs: [pid_t] {
        ([master].compactMap { $0 } + streams).filter(\.isRunning).map(\.pid)
    }

    /// Ends the master (which ends every stream) and stops answering prompts.
    public func close() async {
        isClosed = true
        starting?.cancel()
        await stopMaster()
        for s in streams { s.signal(SIGTERM) }
        for s in streams { _ = await s.waitForExit(timeout: .seconds(2)) }
        streams = []
        askpass?.close()
        askpass = nil
        try? FileManager.default.removeItem(atPath: directory)
    }

    // MARK: - Master

    private var baseEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "SSH_AUTH_SOCK", "LANG"].contains($0.key) }
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    private func startMaster() async throws {
        await stopMaster()
        if askpass == nil {
            askpass = try await AskpassServer.start(path: directory + "/a") { [weak self] text in
                await self?.answer(text)
            }
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.helperPath) else {
            throw SSHTunnelError("Moonrow's SSH helper is missing (\(configuration.helperPath)).")
        }
        var env = baseEnvironment.merging(askpass!.environment) { $1 }
        env["SSH_ASKPASS"] = configuration.helperPath
        env["SSH_ASKPASS_REQUIRE"] = "force"
        asked = []
        typed = [:]
        // Under the helper's guard, so the master can't outlive the app even if the app crashes.
        let process = try Subprocess(
            configuration.helperPath,
            ["--guard", configuration.sshPath] + configuration.masterArguments(controlPath: controlPath),
            environment: env, lifeline: true)
        master = process
        // Logged in once the control socket appears (ssh creates it after authentication).
        while !isSocket(controlPath) {
            if !process.isRunning {
                _ = await process.waitForExit(timeout: .seconds(1))
                master = nil
                let reason = Self.cleaned(process.errors)
                throw SSHTunnelError(reason.isEmpty ? "SSH to \(configuration.server) failed." : reason)
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                process.signal(SIGTERM)
                master = nil
                throw error
            }
        }
        if let a = typed[.password] {
            password = a.text
            if a.save { onSave?(.password, a.text) }
        }
        if let a = typed[.keyPassphrase] {
            keyPassphrase = a.text
            if a.save { onSave?(.keyPassphrase, a.text) }
        }
    }

    private func stopMaster() async {
        if let process = master {
            master = nil
            // ssh closes the connection and removes its control socket on SIGTERM.
            process.signal(SIGTERM)
            if !(await process.waitForExit(timeout: .seconds(2))) { process.signal(SIGKILL) }
        }
        // A master that was killed outright leaves its socket behind; a new one must not be
        // taken for ready because of it.
        unlink(controlPath)
    }

    /// Replies to one askpass prompt; nil cancels.
    private func answer(_ text: String) async -> String? {
        let prompt = SSHPrompt(text)
        let isRetry = !asked.insert(text).inserted
        switch prompt {
        case .password where !isRetry:
            if let password { return password }
        case .keyPassphrase where !isRetry:
            if let keyPassphrase { return keyPassphrase }
        default:
            break
        }
        guard let responder else { return nil }
        let reply = await responder(SSHPromptRequest(prompt: prompt, isRetry: isRetry, server: configuration.server))
        switch prompt {
        case .hostKey:
            return reply == nil ? "no" : "yes"
        case .password:
            typed[.password] = reply
        case .keyPassphrase:
            typed[.keyPassphrase] = reply
        case .other:
            break
        }
        return reply?.text
    }

    private nonisolated func isSocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    /// ssh's error output as a message: progress notes dropped, the `ssh: ` prefix removed.
    static func cleaned(_ errors: String) -> String {
        errors.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !line.hasPrefix("Warning: Permanently added") && !line.hasPrefix("debug")
                    && !line.hasPrefix("Exit request sent") && !line.hasPrefix("**")
            }
            .map { $0.hasPrefix("ssh: ") ? String($0.dropFirst(5)) : $0 }
            .joined(separator: "\n")
    }
}
