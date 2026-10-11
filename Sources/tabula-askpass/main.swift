import Darwin
import Foundation

// SSH_ASKPASS helper. ssh runs it with the prompt as its argument and reads the answer from its
// stdout; it relays the prompt to the Tabula process that started ssh (socket and token in the
// environment) and prints what the user answered. Exits 1 when the user cancels.

let environment = ProcessInfo.processInfo.environment
guard let path = environment["TABULA_ASKPASS_SOCKET"], let token = environment["TABULA_ASKPASS_TOKEN"] else {
    fputs("tabula-askpass: only Tabula runs this\n", stderr)
    exit(2)
}
// A notification with no answer (e.g. "touch your security key"): ssh doesn't wait for it.
if environment["SSH_ASKPASS_PROMPT"] == "none" { exit(0) }

let prompt = CommandLine.arguments.dropFirst().first ?? ""

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(1) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let capacity = MemoryLayout.size(ofValue: address.sun_path)
guard path.utf8.count < capacity else { exit(1) }
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
    fputs("tabula-askpass: Tabula isn't listening\n", stderr)
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
