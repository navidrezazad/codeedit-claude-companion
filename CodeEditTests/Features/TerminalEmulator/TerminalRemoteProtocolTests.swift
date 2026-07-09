//
//  TerminalRemoteProtocolTests.swift
//  CodeEditTests
//

import Foundation
import XCTest
@testable import CodeEdit

final class TerminalRemoteProtocolTests: XCTestCase {
    func testProjectedOutputRoundTripPreservesSnapshotAndCursor() throws {
        let output = TerminalRemoteProtocol.ProjectedOutput(
            sequence: 42,
            generation: 3,
            isSnapshot: true,
            screenMode: .alternate,
            columns: 120,
            terminalRows: 40,
            cursor: .init(
                row: 39,
                column: 8,
                isVisible: true,
                shape: .bar,
                isBlinking: false
            ),
            rows: [
                .init(row: 38, text: "Claude Code"),
                .init(row: 39, text: "")
            ]
        )

        let data = try JSONEncoder().encode(output)
        let decoded = try JSONDecoder().decode(TerminalRemoteProtocol.ProjectedOutput.self, from: data)

        XCTAssertEqual(decoded, output)
    }

    func testProjectedOutputDecodesProtocolV1Payload() throws {
        let data = Data(
            #"{"sequence":7,"screenMode":"main","columns":80,"terminalRows":24,"rows":[{"row":0,"text":"ready"}]}"#
                .utf8
        )

        let decoded = try JSONDecoder().decode(TerminalRemoteProtocol.ProjectedOutput.self, from: data)

        XCTAssertEqual(decoded.sequence, 7)
        XCTAssertNil(decoded.generation)
        XCTAssertNil(decoded.isSnapshot)
        XCTAssertNil(decoded.cursor)
        XCTAssertEqual(decoded.rows.first?.text, "ready")
    }
}
