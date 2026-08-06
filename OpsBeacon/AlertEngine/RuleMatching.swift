import Foundation

enum RuleValidationError: Error, LocalizedError, Equatable {
    case invalidRegularExpression(ruleID: UUID, pattern: String)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidRegularExpression(_, let pattern): "Invalid regular expression: \(pattern)"
        case .invalidConfiguration(let message): message
        }
    }
}

extension Rule {
    func validate() throws {
        if case .log(.regularExpression(let pattern, let caseSensitive)) = matcher {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            do { _ = try NSRegularExpression(pattern: pattern, options: options) }
            catch { throw RuleValidationError.invalidRegularExpression(ruleID: id, pattern: pattern) }
        }
        if case .push(_, let conditions) = matcher,
           conditions.contains(where: { $0.operation != .exists && $0.operand == nil }) {
            throw RuleValidationError.invalidConfiguration("Every non-exists Push condition needs an operand.")
        }
    }

    func matches(_ signal: Signal) -> Bool {
        switch (matcher, signal) {
        case (.log(let matcher), .log(let signal)):
            return matcher.matches(signal.message)
        case (.push(let name, let conditions), .push(let signal)):
            guard name == nil || name == signal.name else { return false }
            let root = JSONValue.object(signal.attributes)
            return conditions.allSatisfy { $0.matches(root) }
        default:
            return false
        }
    }
}

private extension LogRuleMatcher {
    func matches(_ message: String) -> Bool {
        switch self {
        case .contains(let pattern, let caseSensitive):
            let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            return message.range(of: pattern, options: options, range: nil, locale: Locale(identifier: "en_US_POSIX")) != nil
        case .regularExpression(let pattern, let caseSensitive):
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
            let range = NSRange(message.startIndex..., in: message)
            return expression.firstMatch(in: message, options: [], range: range) != nil
        }
    }
}

private extension PushCondition {
    func matches(_ root: JSONValue) -> Bool {
        let value = path.value(in: root)
        switch operation {
        case .exists: return value != nil
        case .equals: return value == operand
        case .notEquals: return value != nil && value != operand
        case .contains:
            guard case .string(let source)? = value, case .string(let needle)? = operand else { return false }
            return source.range(of: needle, options: [], range: nil, locale: Locale(identifier: "en_US_POSIX")) != nil
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            guard case .number(let source)? = value,
                  case .number(let target)? = operand,
                  let sourceDecimal = Decimal(string: source, locale: Locale(identifier: "en_US_POSIX")),
                  let targetDecimal = Decimal(string: target, locale: Locale(identifier: "en_US_POSIX")) else { return false }
            switch operation {
            case .greaterThan: return sourceDecimal > targetDecimal
            case .greaterThanOrEqual: return sourceDecimal >= targetDecimal
            case .lessThan: return sourceDecimal < targetDecimal
            case .lessThanOrEqual: return sourceDecimal <= targetDecimal
            default: return false
            }
        }
    }
}
