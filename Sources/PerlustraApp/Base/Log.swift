import Foundation
import os

/// Persistent diagnostics for failures users report (~/Library/Logs/Perlustra.log). Never contains file contents.
enum Log {
    private static let queue = DispatchQueue(label: "perlustra.log")
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Perlustra.log")

    static func write(_ message: String) {
        debugLog(message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

func debugLog(_ s: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["PERLUSTRA_DEBUG"] != nil {
        FileHandle.standardError.write(Data(("[perlustra] " + s() + "\n").utf8))
    }
}
