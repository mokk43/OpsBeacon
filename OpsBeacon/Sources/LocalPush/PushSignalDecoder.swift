import Foundation

public enum PushSignalDecodingError: Error, LocalizedError, Equatable {
    case bodyTooLarge
    case invalidEnvelope(String)

    public var errorDescription: String? {
        switch self {
        case .bodyTooLarge: "The Push request body exceeds 256 KiB."
        case .invalidEnvelope(let detail): detail
        }
    }
}

public enum PushSignalDecoder {
    public static let maximumBodyBytes = 256 * 1024
    public static let maximumNameScalars = 256
    public static let maximumMessageBytes = 32 * 1024

    public static func decode(_ data: Data, receiptTime: Date) throws -> PushSignal {
        guard data.count <= maximumBodyBytes else { throw PushSignalDecodingError.bodyTooLarge }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PushSignalDecodingError.invalidEnvelope("The Push envelope must be a JSON object.")
        }
        let allowed = Set(["name", "message", "occurredAt", "attributes"])
        guard object.keys.allSatisfy(allowed.contains) else {
            throw PushSignalDecodingError.invalidEnvelope("The Push envelope contains an unknown field.")
        }
        guard let name = object["name"] as? String, !name.isEmpty, name.unicodeScalars.count <= maximumNameScalars else {
            throw PushSignalDecodingError.invalidEnvelope("name must be a nonempty string of at most 256 Unicode scalar values.")
        }
        let message: String?
        if let raw = object["message"] {
            guard let value = raw as? String, value.utf8.count <= maximumMessageBytes else {
                throw PushSignalDecodingError.invalidEnvelope("message must be a string of at most 32 KiB.")
            }
            message = value
        } else {
            message = nil
        }
        let occurredAt: Date
        if let raw = object["occurredAt"] {
            guard let text = raw as? String, hasTimezone(text), let date = parseISO8601(text) else {
                throw PushSignalDecodingError.invalidEnvelope("occurredAt must be an ISO 8601 timestamp with a timezone.")
            }
            occurredAt = date
        } else {
            occurredAt = receiptTime
        }
        let attributes: [String: JSONValue]
        if let raw = object["attributes"] {
            guard raw is [String: Any], JSONSerialization.isValidJSONObject(raw),
                  let encoded = try? JSONSerialization.data(withJSONObject: raw),
                  let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: encoded) else {
                throw PushSignalDecodingError.invalidEnvelope("attributes must be a JSON object.")
            }
            attributes = decoded
        } else {
            attributes = [:]
        }
        return PushSignal(name: name, message: message, occurredAt: occurredAt, attributes: attributes)
    }

    private static func hasTimezone(_ text: String) -> Bool {
        text.range(of: "(Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) != nil
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }()
    }
}
