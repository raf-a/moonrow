import CryptoKit
import Darwin
import Foundation
import NIOSSL

/// The server's self-signed certificate, for remote access.
public struct MCPCertificate: Codable, Sendable, Hashable {
    public var certificatePEM: String
    public var keyPEM: String
    /// The names it was made for, so a change makes another.
    public var hosts: [String]
    public var expires: Date

    /// SHA-256 of the certificate's DER, lowercase hex: what the bridge pins.
    public var fingerprint: String { MCPTLS.fingerprint(pem: certificatePEM) ?? "" }
}

public enum MCPTLS {
    public static let commonName = "Moonrow MCP Server"
    static let lifetime: TimeInterval = 365 * 24 * 3600

    /// localhost, the Mac's host name and its addresses (loopback included), sorted. A remote
    /// client that installs the certificate checks the address it connects to against these, so
    /// the certificate is made again when the addresses change (and its fingerprint with it).
    public static func hosts() -> [String] {
        var names: Set<String> = ["localhost", "127.0.0.1", "::1"]
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let name = text(buffer)
            if !name.isEmpty { names.insert(name.lowercased()) }
        }
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let a = p {
                defer { p = a.pointee.ifa_next }
                guard let addr = a.pointee.ifa_addr else { continue }
                let family = Int32(addr.pointee.sa_family)
                guard family == AF_INET || family == AF_INET6 else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let address = text(host)
                // Link-local IPv6 addresses carry a zone (`fe80::1%en0`) a certificate can't name.
                if !address.contains("%") { names.insert(address) }
            }
            freeifaddrs(first)
        }
        return names.sorted()
    }

    /// The stored certificate, or a new one (stored) when there's none, it expires within a
    /// week, or `hosts` changed.
    public static func certificate(storage: any MCPTokenStorage, hosts: [String] = hosts(), now: Date = Date()) throws -> MCPCertificate {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try storage.load(), let cert = try? decoder.decode(MCPCertificate.self, from: data),
           cert.hosts == hosts, cert.expires.timeIntervalSince(now) > 7 * 24 * 3600 {
            return cert
        }
        let cert = try generate(hosts: hosts, now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try storage.save(encoder.encode(cert))
        return cert
    }

    /// Makes an EC P-256 certificate with `/usr/bin/openssl`.
    public static func generate(hosts: [String], now: Date = Date()) throws -> MCPCertificate {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "moonrow-mcp-tls-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let key = dir.appending(path: "key.pem"), cert = dir.appending(path: "cert.pem")
        let san = hosts.map { isIPAddress($0) ? "IP:\($0)" : "DNS:\($0)" }.joined(separator: ",")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            // A named curve: LibreSSL otherwise writes the curve's parameters out, which BoringSSL refuses.
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-pkeyopt", "ec_param_enc:named_curve", "-nodes",
            "-keyout", key.path, "-out", cert.path, "-days", "365", "-subj", "/CN=\(commonName)",
            "-addext", "subjectAltName=\(san)", "-addext", "extendedKeyUsage=serverAuth",
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MCPToolError("Couldn't make the certificate: " + String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return MCPCertificate(
            certificatePEM: try String(contentsOf: cert, encoding: .utf8), keyPEM: try String(contentsOf: key, encoding: .utf8),
            hosts: hosts, expires: now.addingTimeInterval(lifetime))
    }

    public static func context(_ cert: MCPCertificate) throws -> NIOSSLContext {
        let chain = try NIOSSLCertificate.fromPEMBytes(Array(cert.certificatePEM.utf8)).map { NIOSSLCertificateSource.certificate($0) }
        let key = try NIOSSLPrivateKey(bytes: Array(cert.keyPEM.utf8), format: .pem)
        var config = TLSConfiguration.makeServerConfiguration(certificateChain: chain, privateKey: .privateKey(key))
        config.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: config)
    }

    public static func fingerprint(pem: String) -> String? {
        guard let der = der(pem: pem) else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// The first certificate's DER bytes.
    static func der(pem: String) -> Data? {
        guard let start = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = pem.range(of: "-----END CERTIFICATE-----", range: start.upperBound..<pem.endIndex) else { return nil }
        let base64 = pem[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        return Data(base64Encoded: String(base64))
    }

    private static func text(_ chars: [CChar]) -> String {
        String(decoding: chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }
}
