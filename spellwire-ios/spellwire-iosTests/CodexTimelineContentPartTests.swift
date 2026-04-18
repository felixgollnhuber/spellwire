import XCTest
@testable import spellwire_ios

final class CodexTimelineContentPartTests: XCTestCase {
    func testFromJSONValuePreservesOrderingForMixedMessageContent() {
        let json: JSONValue = .array([
            .object([
                "type": .string("text"),
                "text": .string("Please inspect this")
            ]),
            .object([
                "type": .string("localImage"),
                "path": .string("/tmp/chat/upload.png")
            ]),
            .object([
                "type": .string("mention"),
                "name": .string("workspace")
            ]),
            .object([
                "type": .string("image"),
                "url": .string("https://example.com/reference.png")
            ]),
        ])

        XCTAssertEqual(
            CodexTimelineContentPart.from(jsonValue: json),
            [
                .text("Please inspect this"),
                .localImage(path: "/tmp/chat/upload.png"),
                .mention(name: "workspace", path: nil),
                .image(url: "https://example.com/reference.png"),
            ]
        )
    }
}
