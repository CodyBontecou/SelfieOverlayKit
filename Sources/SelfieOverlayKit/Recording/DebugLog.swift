import Foundation
import os

/// Lightweight logger that writes recording-pipeline events to stdout and the
/// unified log. Messages are marked `.public` so they are not redacted to
/// `<private>` in the Xcode console when you attach to a running process.
/// Filter the console by "SelfieOverlayKit" to isolate.
enum DebugLog {
    private static let logger = Logger(subsystem: "SelfieOverlayKit", category: "pipeline")

    static func log(_ category: String, _ message: String) {
        let line = "[SelfieOverlayKit.\(category)] \(message)"
        print(line)
        logger.notice("\(line, privacy: .public)")
    }
}
