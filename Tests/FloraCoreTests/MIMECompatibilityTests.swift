import Foundation
import Testing
@testable import FloraCore

@Suite("MIME compatibility and bounded recovery")
struct MIMECompatibilityTests {
    private let plain = #"("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 12 1 NIL NIL)"#
    private let html = #"("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 16 1 NIL NIL)"#
    private func metadata(_ structure: String) throws -> IMAPMessageMetadata {
        let headers = "From: Fixture <sender@example.test>\r\nSubject: Source subject\r\n\r\n"
        let line = "* 1 FETCH (UID 7 FLAGS () BODYSTRUCTURE \(structure) BODY[HEADER] {\(headers.utf8.count)}\r\n\(headers))\r\n"
        return try IMAPMapping.metadata(IMAPResponse(lines: [line]), uid: 7)
    }

    @Test func continuedFilenameDecodesSplitMultibyteCharacters() {
        let parameters = MIMEParser.decodeParameters(["filename": "fallback.pdf", "filename*0*": "utf-8''%E7%A0", "filename*1*": "%94%E7%A9%B6", "filename*2": " notes.pdf"])
        #expect(parameters["filename"] == "研究 notes.pdf")
        #expect(MIMEParser.decodeParameters(["filename": "fallback.txt", "filename*0*": "utf-8''start", "filename*2*": "end"])["filename"] == "fallback.txt")
        #expect(MIMEParser.decodeParameters(["filename": "fallback.txt", "filename*": "utf-8''bad%XY"])["filename"] == "fallback.txt")
        #expect(MIMEParser.headerParameters(#"attachment; filename="budget; \"final\".csv""#)["filename"] == "budget; \"final\".csv")
    }

    @Test func commonCharsetsAndByteOrderMarksRemainReadable() {
        #expect(MIMEParser.decodeText(Data([0xD6, 0xD0, 0xCE, 0xC4]), charset: "gb2312") == "中文")
        #expect(MIMEParser.decodeText(Data([0x93, 0xFA, 0x96, 0x7B]), charset: "x-sjis") == "日本")
        #expect(MIMEParser.decodeText(Data([0x93, 0x48, 0x69, 0x94]), charset: "cp1252") == "“Hi”")
        #expect(MIMEParser.decodeText(Data([0xFF, 0xFE, 0x48, 0, 0x69, 0]), charset: nil) == "Hi")
        #expect(MIMEParser.decodeText(Data([0xEF, 0xBB, 0xBF, 0x48, 0x69]), charset: "UTF-8") == "Hi")
        #expect(MIMEParser.decodeText(Data([0x48, 0x69, 0xE7]), charset: "utf8") == "Hi�")
    }

    @Test func transferDecodingRejectsCorruptionAndSupportsBoundedTruncation() throws {
        #expect(throws: MIMEError.invalidTransferEncoding) { try MIMEParser.decodeTransferValidated(Data("SGVs!bG8=".utf8), encoding: "base64") }
        #expect(throws: MIMEError.invalidTransferEncoding) { try MIMEParser.decodeTransferValidated(Data("bad=QZ".utf8), encoding: "quoted-printable") }
        #expect(throws: MIMEError.unsupportedTransferEncoding) { try MIMEParser.decodeTransferValidated(Data("payload".utf8), encoding: "x-unknown") }
        #expect(String(data: try MIMEParser.decodeTransferValidated(Data("SGVsbG8".utf8), encoding: "base64"), encoding: .utf8) == "Hello")
        #expect(String(data: try MIMEParser.decodeTransferValidated(Data("SGVsbG8gd".utf8), encoding: "base64", allowTruncated: true), encoding: .utf8) == "Hello ")
        #expect(MIMEParser.base64URLDecode("SGVsbG8") == Data("Hello".utf8))
        #expect(MIMEParser.base64URLDecode("SGVs!bG8=") == nil)
    }

    @Test func alternativesDoNotDiscardReadableMixedSiblings() throws {
        let parsed = try metadata("(\(html)(\(html)\(plain) \"ALTERNATIVE\") \"MIXED\")")
        let selected = parsed.parts.filter { $0.isPreferredText && !$0.isAttachment }
        #expect(selected.map(\.section) == ["1", "2.2"])
        #expect(selected.map(\.mimeType) == ["text/html", "text/plain"])
    }

    @Test func relatedRootAndCIDMetadataArePreservedWithoutDownloading() throws {
        let image = #"("IMAGE" "PNG" NIL "<diagram@example.test>" NIL "BASE64" 16 NIL NIL)"#
        let root = #"("TEXT" "HTML" ("CHARSET" "UTF-8") "<root@example.test>" NIL "7BIT" 16 1 NIL NIL)"#
        let parsed = try metadata("(\(image)\(root) \"RELATED\" (\"START\" \"<root@example.test>\") NIL)")
        #expect(parsed.parts[0].isAttachment && parsed.parts[0].isInline)
        #expect(parsed.parts[0].contentID == "diagram@example.test")
        #expect(parsed.parts[1].isPreferredText && !parsed.parts[1].isAttachment)
        #expect(MIMEParser.normalizedContentID(" cid:<image@example.test> ") == "image@example.test")
        #expect(MIMEParser.normalizedContentID("<bad\nidentifier>") == nil)
    }

    @Test func nestedAttachmentNeverBecomesAnAutomaticTextPreview() throws {
        let parsed = try metadata("(\(plain) \"MIXED\" NIL (\"ATTACHMENT\" (\"FILENAME\" \"forwarded.mime\")))")
        #expect(parsed.parts.allSatisfy { $0.isAttachment })
        #expect(!parsed.parts.contains { $0.isPreferredText && !$0.isAttachment })
    }

    @Test func forwardedEnvelopeProvidesNameAndInlineNestedSection() throws {
        let envelope = #"(NIL "=?UTF-8?B?56CU56m2?= notes" NIL NIL NIL NIL NIL NIL NIL NIL)"#
        let attached = try metadata("(\"MESSAGE\" \"RFC822\" NIL NIL NIL \"7BIT\" 100 \(envelope) \(plain) 2 NIL (\"ATTACHMENT\" NIL))")
        #expect(attached.parts[0].isAttachment)
        #expect(attached.parts[0].name == "Forwarded — 研究 notes.eml")
        let inline = try metadata("(\(plain)(\"MESSAGE\" \"RFC822\" NIL NIL NIL \"7BIT\" 100 \(envelope) \(plain) 2 NIL (\"INLINE\" NIL)) \"MIXED\")")
        #expect(inline.parts.map(\.section) == ["1", "2.1"])
        #expect(inline.parts[1].forwardedHeader == "Forwarded message: 研究 notes")
        #expect(!inline.parts[1].isAttachment)
    }

    @Test func malformedNestedPartPreservesSiblingAndMetadata() throws {
        let parsed = try metadata("(\(plain)(\"TEXT\" \"HTML\" NIL NIL NIL \"7BIT\" -8) \"MIXED\")")
        #expect(parsed.headers["subject"] == "Source subject")
        #expect(parsed.parts.map(\.section) == ["1"])
        #expect(!parsed.warnings.isEmpty)
        let unsupported = try metadata(#"("TEXT" "PLAIN" NIL NIL NIL "7BIT" -1)"#)
        #expect(unsupported.parts.isEmpty)
        #expect(!unsupported.warnings.isEmpty)
    }

    @Test(arguments: ["invalid", "0", "4294967296", "NIL"])
    func invalidExplicitUIDCannotBecomeAnAuthoritativeDeletion(_ uid: String) {
        #expect(throws: IMAPError.malformedResponse) {
            try IMAPMapping.flagStates(IMAPResponse(lines: ["* 1 FETCH (UID \(uid) FLAGS (\\Seen))"]))
        }
    }

    @Test func incompleteFlagRecordCannotLookLikeADeletedMessage() {
        #expect(throws: IMAPError.malformedResponse) {
            try IMAPMapping.flagStates(IMAPResponse(lines: ["* 1 FETCH (FLAGS (\\Seen) UID)"]))
        }
    }

    @Test func missingLiteralIsNotRenderedAsNILAndCaseInsensitiveItemsParse() throws {
        #expect(throws: IMAPError.malformedResponse) { try IMAPMapping.body(IMAPResponse(lines: ["* 1 FETCH (UID 7 BODY[1] NIL)"]), uid: 7, section: "1") }
        let response = IMAPResponse(lines: ["* 1 fetch (uid 7 body[1] {2}\r\nHi)\r\n"])
        #expect(try IMAPMapping.body(response, uid: 7, section: "1") == Data("Hi".utf8))
    }
}
