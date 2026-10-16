import XCTest
@testable import KernalMobile

final class OfflineRuntimeTests: XCTestCase {
    func testRetrievalQueryIsBoundedByUTF8BytesAndWordCount() {
        let input = String(repeating: "語言偏好 ", count: 1000)
        let query = OfflineRuntime.retrievalQuery(input)
        XCTAssertLessThanOrEqual(query.utf8.count, 512)
        XCTAssertLessThanOrEqual(query.split(separator: " ").count, 32)
        XCTAssertFalse(query.isEmpty)
    }

    func testRetrievalSelectionDoesNotAlterTheUserPrompt() {
        let input = String(repeating: "a", count: 1000) + " Swift Rust"
        let query = OfflineRuntime.retrievalQuery(input)
        XCTAssertEqual(query, "Swift Rust")
        XCTAssertEqual(input.utf8.count, 1011)
        XCTAssertEqual(OfflineRuntime.retrievalQuery("***"), "")
    }
}
