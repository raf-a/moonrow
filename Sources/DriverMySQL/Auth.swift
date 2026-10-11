import CryptoKit
import DBKit
import Foundation
import Security

/// Password scrambles for MySQL's authentication plugins.
enum MySQLAuth {
    /// mysql_native_password: SHA1(pw) XOR SHA1(nonce + SHA1(SHA1(pw))).
    static func nativePassword(_ password: String, nonce: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let stage1 = Array(Insecure.SHA1.hash(data: Data(password.utf8)))
        let stage2 = Array(Insecure.SHA1.hash(data: Data(stage1)))
        let mix = Array(Insecure.SHA1.hash(data: Data(nonce + stage2)))
        return zip(stage1, mix).map { $0 ^ $1 }
    }

    /// caching_sha2_password's fast path: SHA256(pw) XOR SHA256(SHA256(SHA256(pw)) + nonce).
    static func cachingSHA2(_ password: String, nonce: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let stage1 = Array(SHA256.hash(data: Data(password.utf8)))
        let stage2 = Array(SHA256.hash(data: Data(stage1)))
        let mix = Array(SHA256.hash(data: Data(stage2 + nonce)))
        return zip(stage1, mix).map { $0 ^ $1 }
    }

    /// The password for a full authentication over an unencrypted link: NUL-terminated,
    /// XORed with the nonce, then RSA-OAEP (SHA-1) encrypted with the server's public key.
    static func rsaEncryptedPassword(_ password: String, nonce: [UInt8], publicKeyPEM: String) throws -> [UInt8] {
        let key = try publicKey(fromPEM: publicKeyPEM)
        var plain = Array(password.utf8) + [0]
        if !nonce.isEmpty {
            for i in plain.indices { plain[i] ^= nonce[i % nonce.count] }
        }
        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(plain) as CFData, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw DatabaseError("Couldn't encrypt the password with the server's RSA key: \(reason)")
        }
        return Array(encrypted as Data)
    }

    /// Accepts `BEGIN PUBLIC KEY` (SubjectPublicKeyInfo) or `BEGIN RSA PUBLIC KEY` (PKCS#1).
    static func publicKey(fromPEM pem: String) throws -> SecKey {
        let body = pem.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard var der = Data(base64Encoded: String(body)) else {
            throw DatabaseError("The server sent an unreadable RSA public key.")
        }
        if pem.contains("BEGIN PUBLIC KEY") {
            guard let inner = pkcs1(fromSPKI: der) else { throw DatabaseError("The server sent an unreadable RSA public key.") }
            der = inner
        }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw DatabaseError("The server's RSA public key isn't usable: \(error?.takeRetainedValue().localizedDescription ?? "")")
        }
        return key
    }

    /// SubjectPublicKeyInfo ::= SEQUENCE { algorithm SEQUENCE, subjectPublicKey BIT STRING };
    /// the bit string holds the PKCS#1 RSAPublicKey.
    static func pkcs1(fromSPKI der: Data) -> Data? {
        let bytes = [UInt8](der)
        var i = 0
        func header(_ tag: UInt8) -> Int? {
            guard i < bytes.count, bytes[i] == tag else { return nil }
            i += 1
            guard i < bytes.count else { return nil }
            var length = Int(bytes[i])
            i += 1
            if length & 0x80 != 0 {
                let n = length & 0x7F
                guard n <= 4, i + n <= bytes.count else { return nil }
                length = bytes[i..<i + n].reduce(0) { $0 << 8 | Int($1) }
                i += n
            }
            return length
        }
        guard header(0x30) != nil, let algorithm = header(0x30) else { return nil }
        i += algorithm
        guard let bits = header(0x03), bits > 1, i + bits <= bytes.count, bytes[i] == 0 else { return nil }
        return Data(bytes[(i + 1)..<(i + bits)])
    }
}
