import CryptoKit
import DBKit
import Foundation
import NIOCore
import Security
import Testing
@testable import DriverMySQL

@Suite struct MySQLProtocolTests {
    @Test func lengthEncodedIntegers() {
        for v: UInt64 in [0, 1, 250, 251, 0xFFFF, 0x1_0000, 0xFF_FFFF, 0x100_0000, UInt64.max] {
            var b = ByteBuffer()
            b.writeLengthEncodedInteger(v)
            let expectedSize = v < 251 ? 1 : v <= 0xFFFF ? 3 : v <= 0xFF_FFFF ? 4 : 9
            #expect(b.readableBytes == expectedSize, "size for \(v)")
            #expect(b.readLengthEncodedInteger() == v)
            #expect(b.readableBytes == 0)
        }
        var null = ByteBuffer(bytes: [0xFB])
        #expect(null.readLengthEncodedInteger() == nil)
    }

    @Test func framerSplitsPacketsAndWaitsForWholeOnes() throws {
        var b = ByteBuffer(bytes: [3, 0, 0, 0, 0x61, 0x62, 0x63, 1, 0, 0, 1, 0x7A, 5, 0, 0, 2, 1])
        let framer = MySQLFramer()
        let first = try #require(try framer.nextFrame(&b))
        #expect(Array(first.readableBytesView) == [3, 0, 0, 0, 0x61, 0x62, 0x63])
        let second = try #require(try framer.nextFrame(&b))
        #expect(Array(second.readableBytesView) == [1, 0, 0, 1, 0x7A])
        #expect(try framer.nextFrame(&b) == nil)  // 5-byte payload, only 1 byte here
        #expect(b.readableBytes == 5)
    }

    @Test func longPayloadsAreSplitIntoContinuationPackets() throws {
        let size = maxPacketPayload * 2
        var payload = ByteBuffer()
        payload.writeRepeatingByte(7, count: size)
        var sequence: UInt8 = 3
        let packets = PacketChannel.packets(payload, sequence: &sequence, allocator: ByteBufferAllocator())
        // Two full packets, then an empty one to say the payload ended.
        #expect(packets.map { $0.readableBytes - 4 } == [maxPacketPayload, maxPacketPayload, 0])
        #expect(packets.map { $0.getInteger(at: 3, as: UInt8.self) } == [3, 4, 5])
        #expect(sequence == 6)

        var all = ByteBuffer()
        for var p in packets { all.writeBuffer(&p) }
        var lengths: [Int] = []
        while let frame = try MySQLFramer().nextFrame(&all) { lengths.append(frame.readableBytes - 4) }
        #expect(lengths == [maxPacketPayload, maxPacketPayload, 0])

        sequence = 0
        #expect(PacketChannel.packets(ByteBuffer(bytes: [1, 2]), sequence: &sequence, allocator: ByteBufferAllocator()).count == 1)
    }

    /// The server's check: SHA1(response XOR SHA1(nonce + stored)) must equal stored, where
    /// stored is SHA1(SHA1(password)) — the hash in mysql.user.
    @Test func nativePasswordScramble() {
        let nonce = Array("abcdefghijklmnopqrst".utf8)
        let response = MySQLAuth.nativePassword("password", nonce: nonce)
        #expect(response.count == 20)
        let stored = Array(Insecure.SHA1.hash(data: Data(Insecure.SHA1.hash(data: Data("password".utf8)))))
        // The well-known PASSWORD('password') hash.
        #expect(Data(stored).map { String(format: "%02X", $0) }.joined() == "2470C0C06DEE42FD1618BB99005ADCA2EC9D1E19")
        let mix = Array(Insecure.SHA1.hash(data: Data(nonce + stored)))
        let stage1 = zip(response, mix).map { $0 ^ $1 }
        #expect(Array(Insecure.SHA1.hash(data: Data(stage1))) == stored)
        #expect(MySQLAuth.nativePassword("", nonce: nonce).isEmpty)
    }

    /// The server's fast-auth check against its cached SHA256(SHA256(password)).
    @Test func cachingSHA2Scramble() {
        let nonce = Array("01234567890123456789".utf8)
        let response = MySQLAuth.cachingSHA2("sécret", nonce: nonce)
        let stage2 = Array(SHA256.hash(data: Data(SHA256.hash(data: Data("sécret".utf8)))))
        let mix = Array(SHA256.hash(data: Data(stage2 + nonce)))
        let stage1 = zip(response, mix).map { $0 ^ $1 }
        #expect(Array(SHA256.hash(data: Data(stage1))) == stage2)
        #expect(MySQLAuth.cachingSHA2("", nonce: nonce).isEmpty)
    }

    @Test func rsaPasswordEncryptionWithAnSPKIKey() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        // Wrap PKCS#1 in SubjectPublicKeyInfo, as MySQL sends it.
        let algorithm: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let bitString = [0x03] + derLength(pkcs1.count + 1) + [0x00] + [UInt8](pkcs1)
        let spki = [0x30] + derLength(algorithm.count + bitString.count) + algorithm + bitString
        #expect(MySQLAuth.pkcs1(fromSPKI: Data(spki)) == pkcs1)
        let pem = "-----BEGIN PUBLIC KEY-----\n" + Data(spki).base64EncodedString(options: .lineLength64Characters)
            + "\n-----END PUBLIC KEY-----\n"

        let nonce = Array("nonce-nonce-nonce-12".utf8)
        let encrypted = try MySQLAuth.rsaEncryptedPassword("pw", nonce: nonce, publicKeyPEM: pem)
        let decrypted = try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionOAEPSHA1, Data(encrypted) as CFData, nil) as Data?)
        let plain = decrypted.enumerated().map { $0.element ^ nonce[$0.offset % nonce.count] }
        #expect(plain == Array("pw".utf8) + [0])
    }

    private func derLength(_ n: Int) -> [UInt8] {
        n < 0x80 ? [UInt8(n)] : n <= 0xFF ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
    }

    @Test func textRows() throws {
        let columns = [
            ColumnDefinition(name: "i", type: FieldType.long),
            ColumnDefinition(name: "u", type: FieldType.longlong, flags: 0x20),
            ColumnDefinition(name: "f", type: FieldType.double),
            ColumnDefinition(name: "s", type: FieldType.varString),
            ColumnDefinition(name: "b", type: FieldType.blob, characterSet: 63),
            ColumnDefinition(name: "n", type: FieldType.varString),
            ColumnDefinition(name: "bit", type: FieldType.bit, characterSet: 63),
        ]
        var p = ByteBuffer()
        for cell in ["-7", "18446744073709551615", "2.5", "héllo"] { p.writeLengthEncodedBytes(Array(cell.utf8)) }
        p.writeLengthEncodedBytes([0, 1, 0xFF])
        p.writeInteger(UInt8(0xFB))
        p.writeLengthEncodedBytes([0x01, 0x02])
        #expect(try ValueDecoding.textRow(p, columns: columns) == [
            .integer(-7), .text("18446744073709551615"), .double(2.5), .text("héllo"), .blob(Data([0, 1, 0xFF])),
            .null, .integer(258),
        ])
    }

    @Test func binaryRows() throws {
        let columns = [
            ColumnDefinition(name: "t", type: FieldType.tiny),
            ColumnDefinition(name: "tu", type: FieldType.tiny, flags: 0x20),
            ColumnDefinition(name: "n", type: FieldType.long),
            ColumnDefinition(name: "ll", type: FieldType.longlong),
            ColumnDefinition(name: "f", type: FieldType.float),
            ColumnDefinition(name: "d", type: FieldType.double),
            ColumnDefinition(name: "dt", type: FieldType.datetime, decimals: 3),
            ColumnDefinition(name: "date", type: FieldType.date),
            ColumnDefinition(name: "tm", type: FieldType.time),
            ColumnDefinition(name: "dec", type: FieldType.newDecimal),
            ColumnDefinition(name: "s", type: FieldType.varString),
        ]
        var p = ByteBuffer()
        p.writeInteger(UInt8(0))
        // NULL bitmap, offset by 2 bits: column 2 ("n") is NULL -> bit 4.
        p.writeBytes([0b0001_0000, 0])
        p.writeInteger(UInt8(0xFF))                    // -1
        p.writeInteger(UInt8(0xFF))                    // 255 unsigned
        p.writeInteger(Int64(-5), endianness: .little)
        p.writeInteger(Float(0.1).bitPattern, endianness: .little)
        p.writeInteger(Double(1.25).bitPattern, endianness: .little)
        p.writeBytes([11]); p.writeInteger(UInt16(2024), endianness: .little)
        p.writeBytes([2, 29, 13, 5, 9]); p.writeInteger(UInt32(123_456), endianness: .little)
        p.writeBytes([4]); p.writeInteger(UInt16(1999), endianness: .little); p.writeBytes([12, 31])
        p.writeBytes([8, 1]); p.writeInteger(UInt32(1), endianness: .little); p.writeBytes([2, 3, 4])
        p.writeLengthEncodedBytes(Array("12.50".utf8))
        p.writeLengthEncodedBytes(Array("x".utf8))
        #expect(try ValueDecoding.binaryRow(p, columns: columns) == [
            .integer(-1), .integer(255), .null, .integer(-5), .double(0.1), .double(1.25),
            .text("2024-02-29 13:05:09.123"), .text("1999-12-31"), .text("-26:03:04"), .text("12.50"), .text("x"),
        ])
    }

    @Test func parameterEncoding() {
        var b = ByteBuffer()
        ParameterEncoding.write([.integer(1), .null, .text("ab"), .bool(true)], into: &b)
        #expect(Array(b.readableBytesView) == [
            0b0000_0010, 1,
            FieldType.longlong, 0, FieldType.null, 0, FieldType.varString, 0, FieldType.tiny, 0,
            1, 0, 0, 0, 0, 0, 0, 0,
            2, 0x61, 0x62,
            1,
        ])
    }
}
