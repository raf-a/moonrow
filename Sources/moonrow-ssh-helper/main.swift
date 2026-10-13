import Darwin
import Foundation

// Moonrow's companion for SSH tunnels, with two jobs:
//
//   moonrow-ssh-helper --guard <ssh> <args…>
//       Runs ssh as its child until either ends. Its stdin is a pipe from Moonrow: when that
//       closes (Moonrow quit or crashed) it stops ssh, so no tunnel outlives the app. SIGTERM is
//       passed on to ssh; it exits with ssh's status.
//
//   moonrow-ssh-helper <prompt>          (as SSH_ASKPASS)
//       ssh runs it with the prompt as its argument and reads the answer from its stdout. It
//       relays the prompt to the Moonrow process that started ssh (socket and token in the
//       environment) and prints what the user answered; exits 1 when the user cancels.

let arguments = CommandLine.arguments
if arguments.count > 2, arguments[1] == "--guard" {
    guardChild(Array(arguments.dropFirst(2)))
} else {
    askpass(arguments.dropFirst().first ?? "")
}

func guardChild(_ command: [String]) -> Never {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    // Our stdin (the pipe from Moonrow) stays with us; ssh gets stdout/stderr and nothing else.
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawn_file_actions_addinherit_np(&actions, 1)
    posix_spawn_file_actions_addinherit_np(&actions, 2)
    let argv = command.map { strdup($0) } + [nil]
    var child: pid_t = 0
    let status = posix_spawn(&child, command[0], &actions, &attributes, argv, environ)
    guard status == 0 else {
        fputs("Can't start \(command[0]): \(String(cString: strerror(status)))\n", stderr)
        exit(127)
    }
    let pid = child

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    var sources: [any DispatchSourceSignal] = []
    for s in [SIGTERM, SIGINT, SIGHUP] {
        let source = DispatchSource.makeSignalSource(signal: s, queue: .global())
        source.setEventHandler { kill(pid, SIGTERM) }
        source.resume()
        sources.append(source)
    }
    Thread.detachNewThread {
        var byte: UInt8 = 0
        while true {
            let n = read(0, &byte, 1)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
        }
        // Moonrow is gone.
        kill(pid, SIGTERM)
        sleep(3)
        kill(pid, SIGKILL)
    }
    var result: Int32 = 0
    while waitpid(pid, &result, 0) < 0, errno == EINTR {}
    _ = sources
    exit((result & 0x7F) == 0 ? (result >> 8) & 0xFF : 128 + (result & 0x7F))
}

func askpass(_ prompt: String) -> Never {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["MOONROW_ASKPASS_SOCKET"], let token = environment["MOONROW_ASKPASS_TOKEN"] else {
        fputs("moonrow-ssh-helper: only Moonrow runs this\n", stderr)
        exit(2)
    }
    // A notification with no answer (e.g. "touch your security key"): ssh doesn't wait for it.
    if environment["SSH_ASKPASS_PROMPT"] == "none" { exit(0) }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { exit(1) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { exit(1) }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: path.utf8)
        raw[path.utf8.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        fputs("moonrow-ssh-helper: Moonrow isn't listening\n", stderr)
        exit(1)
    }

    var request = (try? JSONSerialization.data(withJSONObject: ["token": token, "prompt": prompt])) ?? Data()
    request.append(UInt8(ascii: "\n"))
    let sent = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard sent == request.count else { exit(1) }

    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { break }
        reply.append(contentsOf: buffer[0..<n])
        if reply.contains(UInt8(ascii: "\n")) { break }
    }
    close(fd)

    guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
          let answer = object["answer"] as? String
    else { exit(1) }
    print(answer)
    exit(0)
}
