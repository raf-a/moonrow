// Checks a Sparkle EdDSA signature the way the app will: the file's bytes against the base64
// public key from SUPublicEDKey.
// Usage: swift scripts/verify-ed25519.swift <file> <base64 signature> <base64 public key>
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: verify-ed25519.swift <file> <signature> <public key>\n".utf8))
    exit(2)
}
guard let file = FileManager.default.contents(atPath: args[1]),
      let signature = Data(base64Encoded: args[2]),
      let keyData = Data(base64Encoded: args[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else {
    FileHandle.standardError.write(Data("error: unreadable file, signature or public key\n".utf8))
    exit(1)
}
guard key.isValidSignature(signature, for: file) else {
    FileHandle.standardError.write(Data("error: the signature of \(args[1]) doesn't match the public key \(args[3])\n".utf8))
    exit(1)
}
print("\(args[1]): EdDSA signature matches \(args[3])")
