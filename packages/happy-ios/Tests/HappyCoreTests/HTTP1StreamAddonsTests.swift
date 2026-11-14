import CryptoKit
import Foundation
import XCTest

/// `stream(path:credential:headers:)` in HTTP1Stream.swift hands every call
/// to our plugins' `stream(…within:)` (HTTP1Stream+Addons.swift), so
/// upstream's body after that first line is not run. This pins upstream's
/// body: when a merge changes it, this fails until the change is carried
/// into HTTP1Stream+Addons.swift and the hash below is updated.
final class HTTP1StreamAddonsTests: XCTestCase {
    static let upstreamBody = "6a8fda15a0f0f90e5d7d3db5c45a56390555b90b8caaabd6c08008788f1745ed"

    func testUpstreamStreamBodyIsTheOneOursFollows() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HappyCore/AgentConnection/HTTP1Stream.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let signature = "    public func stream(path: String, credential: String, headers: [String: String]) async throws -> HTTP1Stream {\n"
        let start = try XCTUnwrap(text.range(of: signature))
        let end = try XCTUnwrap(text.range(of: "\n    }\n", range: start.lowerBound..<text.endIndex))
        let body = text[start.lowerBound..<end.upperBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("headDeadlineFromCall") }
            .joined(separator: "\n")
        let hash = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, Self.upstreamBody, "upstream's stream() changed: carry the change into HTTP1Stream+Addons.swift, then update the hash")
    }
}
