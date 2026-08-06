import Foundation

public struct LogFramingResult: Equatable, Sendable {
    public var lines: [String]
    public var oversizedLineCount: Int

    public init(lines: [String] = [], oversizedLineCount: Int = 0) {
        self.lines = lines
        self.oversizedLineCount = oversizedLineCount
    }
}

/// A bounded, newline-delimited framer. It intentionally never exposes a truncated line.
public struct LogLineFramer: Sendable {
    private let maximumLineBytes: Int
    private var lineBytes: [UInt8] = []
    private var discardingOversizedLine = false
    private var uncommittedBytes = 0

    public init(maximumLineBytes: Int = 256 * 1024) {
        precondition(maximumLineBytes > 0)
        self.maximumLineBytes = maximumLineBytes
        lineBytes.reserveCapacity(min(maximumLineBytes, 4_096))
    }

    public mutating func append(_ bytes: Data) -> LogFramingResult {
        var result = LogFramingResult()
        for byte in bytes {
            uncommittedBytes += 1
            if discardingOversizedLine {
                if byte == 0x0A {
                    discardingOversizedLine = false
                    result.oversizedLineCount += 1
                    uncommittedBytes = 0
                }
                continue
            }
            if byte == 0x0A {
                if lineBytes.last == 0x0D { lineBytes.removeLast() }
                result.lines.append(String(decoding: lineBytes, as: UTF8.self))
                lineBytes.removeAll(keepingCapacity: true)
                uncommittedBytes = 0
                continue
            }
            lineBytes.append(byte)
            if lineBytes.count > maximumLineBytes {
                lineBytes.removeAll(keepingCapacity: true)
                discardingOversizedLine = true
            }
        }
        return result
    }

    public var hasIncompleteLine: Bool { discardingOversizedLine || !lineBytes.isEmpty }
    public var uncommittedByteCount: Int { uncommittedBytes }
}
