import Foundation

/// Append-only JSON Lines log with size-based rotation.
///
/// When the log reaches `maxBytes` it's renamed to `<name>-<UTC timestamp>.jsonl` and a new one is
/// started, the same scheme the hook script uses. Rotated logs are kept.
public struct JSONLLog {
    public let url: URL
    public var maxBytes: Int

    public init(url: URL, maxBytes: Int = JSONLLog.defaultMaxBytes) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// `$NICE_SEMAPHORE_LOG_MAX_BYTES`, or 10 MB.
    public static var defaultMaxBytes: Int {
        ProcessInfo.processInfo.environment["NICE_SEMAPHORE_LOG_MAX_BYTES"].flatMap(Int.init) ?? 10 * 1024 * 1024
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func append<T: Encodable>(_ record: T, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded(now: now)

        var line = try JSONLLog.makeEncoder().encode(record)
        line.append(0x0A)

        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    /// Decodes every line of the current log, skipping lines that don't decode as `T`.
    public func records<T: Decodable>(as type: T.Type) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONLLog.makeDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    private func rotateIfNeeded(now: Date) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue >= maxBytes else {
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let name = url.deletingPathExtension().lastPathComponent
        let rotated = url.deletingLastPathComponent().appendingPathComponent("\(name)-\(formatter.string(from: now)).jsonl")
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
}
