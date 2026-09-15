import Foundation
import OSLog

/// Serial disk writes stay off the UI and playback actors. Each record is appended and closed;
/// flush at orderly shutdown. Eight 4 MB archives bound retention across launches.
final class DiagnosticLog: @unchecked Sendable {
    static let shared: DiagnosticLog = {
        // Unit tests exercise fake playback and must not contaminate the listening timeline.
        if Bundle.allBundles.contains(where: { $0.bundleURL.pathExtension == "xctest" }) {
            return DiagnosticLog(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SpotifyLite-test-diagnostics"))
        }
        return DiagnosticLog()
    }()
    private let queue = DispatchQueue(label: "app.spotifylite.diagnostics", qos: .utility)
    private let directory: URL
    private let maximumBytes: Int
    private let archives: Int
    private let session = UUID().uuidString
    private var sequence = 0 // Accessed only on queue.
    private let fallback = Logger(subsystem: "app.spotifylite.SpotifyLite", category: "diagnostics")

    init(directory: URL = SpotifydSupervisorConfiguration.defaultApplicationSupportDirectory
        .appendingPathComponent("Logs"), maximumBytes: Int = 4_000_000, archives: Int = 8) {
        self.directory = directory
        self.maximumBytes = max(256, maximumBytes)
        self.archives = max(1, archives)
    }

    func record(_ event: String, _ fields: [String: String] = [:]) {
        let timestamp = Date().ISO8601Format(.iso8601(timeZone: .gmt, includingFractionalSeconds: true))
        let clean = fields.mapValues { SpotifydSupervisor.redact($0) }
        queue.async { [self] in
            do {
                sequence += 1
                let row = Record(timestamp: timestamp, session: session, sequence: sequence,
                                 event: event, fields: clean)
                var data = try JSONEncoder().encode(row)
                data.append(0x0A)
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent("app.jsonl")
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size + data.count > maximumBytes, size > 0 {
                    for index in stride(from: archives, through: 1, by: -1) {
                        let target = directory.appendingPathComponent("app.jsonl.\(index)")
                        let source = index == 1 ? file : directory.appendingPathComponent("app.jsonl.\(index - 1)")
                        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                        if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: target) }
                    }
                }
                if !fm.fileExists(atPath: file.path) {
                    guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                fallback.error("Unable to append diagnostics (code \((error as NSError).code))")
            }
        }
    }

    func flush() { queue.sync {} }

    private struct Record: Encodable {
        let timestamp: String
        let session: String
        let sequence: Int
        let event: String
        let fields: [String: String]
    }

    static func playback(_ state: PlaybackState?) -> [String: String] {
        guard let state else { return ["state": "none"] }
        return ["track": state.item?.uri ?? "none", "context": state.contextURI ?? "none",
                "position_ms": String(state.progressMS), "playing": String(state.isPlaying),
                "device": state.device?.id ?? "none", "shuffle": String(state.shuffle),
                "repeat": state.repeatMode.rawValue]
    }
}
