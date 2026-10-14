import DBKit
import Foundation
import NIOCore
import Testing
@testable import DriverPostgres

@Suite struct PGUnitTests {
    /// RFC 7677 §3's example exchange.
    @Test func scramMatchesRFC7677() throws {
        var client = SCRAMClient(password: "pencil", user: "user", nonce: "rOprNGfwEbeRWgbNEkqO")
        #expect(client.clientFirst() == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        #expect(try client.clientFinal(serverFirst: serverFirst)
            == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        try client.verify(serverFinal: "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")
        #expect(throws: DatabaseError.self) { try client.verify(serverFinal: "v=AAAA") }
    }

    @Test func scramRejectsANonceTheClientDidntStart() {
        var client = SCRAMClient(password: "pencil", nonce: "abc")
        _ = client.clientFirst()
        #expect(throws: DatabaseError.self) { try client.clientFinal(serverFirst: "r=xyz,s=AAAA,i=4096") }
    }

    @Test func md5Response() {
        let r = PGAuth.md5Response(user: "postgres", password: "secret", salt: [1, 2, 3, 4])
        #expect(r == Array("md5bb41a296aab6baccb36ff243a562abff".utf8) + [0])
    }

    @Test func framerSplitsMessagesAcrossReads() throws {
        var b = ByteBuffer()
        PGFrontend.message("C", into: &b) { $0.writeCString("SELECT 1") }
        PGFrontend.message("Z", into: &b) { $0.writeInteger(UInt8(ascii: "I")) }
        var partial = b.getSlice(at: 0, length: 7)!
        #expect(try PGFramer().nextFrame(&partial) == nil)
        var whole = b
        let first = try #require(try PGFramer().nextFrame(&whole))
        let second = try #require(try PGFramer().nextFrame(&whole))
        #expect(try PGFramer().nextFrame(&whole) == nil)
        var tag = PGMessage(frame: first).body
        #expect(PGMessage(frame: first).kind == "C" && tag.readCString() == "SELECT 1")
        #expect(PGMessage(frame: second).kind == "Z")
    }

    @Test func textValuesBecomeTypedValues() {
        func decode(_ s: String, _ type: UInt32) -> DBValue {
            var b = ByteBuffer(string: s)
            return PGType.decode(&b, length: s.utf8.count, type: type)
        }
        #expect(decode("-42", PGType.int8) == .integer(-42))
        #expect(decode("1.5", PGType.float8) == .double(1.5))
        #expect(decode("-Infinity", PGType.float4) == .double(-.infinity))
        #expect(decode("t", PGType.bool) == .bool(true))
        #expect(decode(#"\x00ff"#, PGType.bytea) == .blob(Data([0, 255])))
        #expect(decode("12.50", 1700) == .text("12.50"))
        #expect(PGType.encode(.blob(Data([1, 0xAB]))) == Array(#"\x01AB"#.utf8))
        #expect(PGType.logged(.text("it's")) == "'it''s'")
    }

    @Test func commandTagCounts() {
        #expect(PGSession.rowCount("INSERT 0 5") == 5)
        #expect(PGSession.rowCount("UPDATE 2") == 2)
        #expect(PGSession.rowCount("CREATE TABLE") == 0)
    }

    /// ErrorResponse's position counts characters from 1; the error carries a UTF-16 offset.
    @Test func errorFieldsAndPosition() {
        var body = ByteBuffer()
        for (code, value) in [("S", "ERROR"), ("C", "42703"), ("M", "column \"nope\" does not exist"), ("H", "Check the name."), ("P", "13")] {
            body.writeInteger(UInt8(ascii: Unicode.Scalar(code)!))
            body.writeCString(value)
        }
        body.writeInteger(UInt8(0))
        let sql = "SELECT '😀', nope"
        let error = PGNotice(body).error(sql: sql)
        #expect(error.message == "column \"nope\" does not exist\nHINT: Check the name.")
        #expect(error.hint == "Check the name." && error.detail == nil && error.state == "42703")
        #expect(error.position == (sql as NSString).range(of: "nope").location)
        #expect(error.localizedDescription == error.message)
        #expect(PGNotice.utf16Offset(ofCharacter: 1, in: "x") == 0)
        #expect(PGNotice.utf16Offset(ofCharacter: 2, in: "x") == nil)
        #expect(PGNotice.utf16Offset(ofCharacter: 0, in: "x") == nil)
    }
}
