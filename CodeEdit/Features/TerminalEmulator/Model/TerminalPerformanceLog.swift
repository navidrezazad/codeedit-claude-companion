//
//  TerminalPerformanceLog.swift
//  CodeEdit
//
//  Created by Claude on 01/05/2026.
//

import Foundation
import OSLog

enum TerminalPerformanceLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CodeEdit",
        category: "TerminalPerformance"
    )

    private static let slowOperationThreshold: UInt64 = 8_000_000

    static func timestamp() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func mark(_ message: @autoclosure () -> String) {
        let message = message()
        logger.debug("\(message, privacy: .public)")
    }

    static func duration(
        _ label: @autoclosure () -> String,
        from start: UInt64,
        threshold: UInt64 = slowOperationThreshold
    ) {
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        guard elapsed >= threshold else {
            return
        }

        let elapsedMilliseconds = String(format: "%.2f", Double(elapsed) / 1_000_000)
        let label = label()
        logger.debug("\(label, privacy: .public) \(elapsedMilliseconds, privacy: .public) ms")
    }
}
