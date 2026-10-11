import CommonCrypto
import CryptoKit
import DBKit
import Foundation

enum PGAuth {
    /// `md5` + md5(md5(password + user) + salt), as hex.
    static func md5Response(user: String, password: String, salt: [UInt8]) -> [UInt8] {
        let inner = hex(Insecure.MD5.hash(data: Data((password + user).utf8)))
        let outer = hex(Insecure.MD5.hash(data: Data(inner.utf8) + Data(salt)))
        return Array(("md5" + outer).utf8) + [0]
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// SCRAM-SHA-256 (RFC 5802/7677) without channel binding, as Postgres runs it. The user name
/// in the messages is empty: the server takes it from the startup packet.
struct SCRAMClient {
    static let mechanism = "SCRAM-SHA-256"

    let password: String
    let clientNonce: String
    let user: String
    private var clientFirstBare = ""
    private var serverSignature: [UInt8] = []

    init(password: String, user: String = "", nonce: String? = nil) {
        self.password = password
        self.user = user
        if let nonce {
            clientNonce = nonce
        } else {
            var bytes = [UInt8](repeating: 0, count: 18)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            clientNonce = Data(bytes).base64EncodedString()
        }
    }

    mutating func clientFirst() -> String {
        clientFirstBare = "n=\(user),r=\(clientNonce)"
        return "n,," + clientFirstBare
    }

    /// The client-final message for the server-first one.
    mutating func clientFinal(serverFirst: String) throws -> String {
        let attributes = Self.attributes(serverFirst)
        guard let nonce = attributes["r"], nonce.hasPrefix(clientNonce),
              let saltText = attributes["s"], let salt = Data(base64Encoded: saltText),
              let iterationText = attributes["i"], let iterations = Int(iterationText), iterations > 0
        else { throw DatabaseError("The server sent an invalid SCRAM challenge.") }

        let salted = Self.pbkdf2(password: Array(password.utf8), salt: Array(salt), iterations: iterations)
        let clientKey = Self.hmac(salted, "Client Key")
        let storedKey = Array(SHA256.hash(data: clientKey))
        let withoutProof = "c=biws,r=\(nonce)"
        let authMessage = "\(clientFirstBare),\(serverFirst),\(withoutProof)"
        let signature = Self.hmac(storedKey, authMessage)
        let proof = zip(clientKey, signature).map { $0 ^ $1 }
        serverSignature = Self.hmac(Self.hmac(salted, "Server Key"), authMessage)
        return withoutProof + ",p=" + Data(proof).base64EncodedString()
    }

    func verify(serverFinal: String) throws {
        let attributes = Self.attributes(serverFinal)
        if let e = attributes["e"] { throw DatabaseError("SCRAM authentication failed: \(e)") }
        guard let v = attributes["v"], let signature = Data(base64Encoded: v), Array(signature) == serverSignature else {
            throw DatabaseError("The server's SCRAM signature doesn't match; it may not know the password.")
        }
    }

    static func attributes(_ message: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in message.split(separator: ",") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            out[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        return out
    }

    static func hmac(_ key: [UInt8], _ message: String) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = password.map { CChar(bitPattern: $0) }
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, out.count)
        return out
    }
}
