import DBKit
import NIOSSL

/// How hard a connection insists on TLS, in libpq's terms. MySQL's modes map onto the same
/// scale: DISABLED, PREFERRED, REQUIRED, VERIFY_CA, VERIFY_IDENTITY.
public enum TLSMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Never.
    case disable
    /// Plain first; TLS only if the server refuses plain connections (Postgres only).
    case allow
    /// TLS when the server offers it, without checking its certificate.
    case prefer
    /// TLS or fail, without checking the certificate.
    case require
    /// TLS with a certificate signed by a trusted CA, any host name.
    case verifyCA
    /// TLS with a trusted certificate issued for the host we connect to.
    case verifyFull

    public var verifiesCertificate: Bool { self == .verifyCA || self == .verifyFull }
}

public struct TLSSettings: Sendable, Hashable {
    public var mode: TLSMode
    /// PEM file of CA certificates to trust instead of the system's.
    public var caCertificatePath: String?
    /// Client certificate and key (PEM), for servers that ask for one.
    public var clientCertificatePath: String?
    public var clientKeyPath: String?
    /// Overrides the host name used for SNI and verification.
    public var serverName: String?

    public init(
        mode: TLSMode = .prefer, caCertificatePath: String? = nil, clientCertificatePath: String? = nil,
        clientKeyPath: String? = nil, serverName: String? = nil
    ) {
        self.mode = mode
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
        self.serverName = serverName
    }

    func configuration(alpn: [String]) throws -> TLSConfiguration {
        var c = TLSConfiguration.makeClientConfiguration()
        switch mode {
        case .verifyFull: c.certificateVerification = .fullVerification
        case .verifyCA: c.certificateVerification = .noHostnameVerification
        default: c.certificateVerification = .none
        }
        do {
            if let ca = caCertificatePath.nonEmpty {
                c.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(ca))
            }
            if let cert = clientCertificatePath.nonEmpty {
                c.certificateChain = try NIOSSLCertificate.fromPEMFile(cert).map { .certificate($0) }
                let key = clientKeyPath.nonEmpty ?? cert
                c.privateKey = .privateKey(try NIOSSLPrivateKey(file: key, format: .pem))
            }
        } catch {
            throw DatabaseError("Can't read the TLS certificate or key files: \(error)")
        }
        c.applicationProtocols = alpn
        return c
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s
    }
}
