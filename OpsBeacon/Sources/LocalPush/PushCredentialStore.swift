import Foundation
import Security

public protocol PushCredentialStore: Sendable {
    func credential(for sourceID: UUID) async throws -> String?
    func generateAndStoreCredential(for sourceID: UUID) async throws -> String
    func deleteCredential(for sourceID: UUID) async throws
}

public enum PushCredentialStoreError: Error, LocalizedError {
    case randomGeneration(OSStatus)
    case keychain(OSStatus)
    case invalidStoredCredential

    public var errorDescription: String? {
        switch self {
        case .randomGeneration: "OpsBeacon could not generate a Push Credential."
        case .keychain: "OpsBeacon could not access the Keychain."
        case .invalidStoredCredential: "The stored Push Credential is invalid."
        }
    }
}

public actor InMemoryPushCredentialStore: PushCredentialStore {
    private var values: [UUID: String] = [:]
    public init() {}
    public func credential(for sourceID: UUID) async throws -> String? { values[sourceID] }
    public func generateAndStoreCredential(for sourceID: UUID) async throws -> String {
        let credential = PushCredentialGenerator.make()
        values[sourceID] = credential
        return credential
    }
    public func deleteCredential(for sourceID: UUID) async throws { values.removeValue(forKey: sourceID) }
}

public actor KeychainPushCredentialStore: PushCredentialStore {
    private let service = "com.opsbeacon.push-credential"
    public init() {}

    public func credential(for sourceID: UUID) async throws -> String? {
        var query = baseQuery(sourceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PushCredentialStoreError.keychain(status) }
        guard let data = result as? Data, let credential = String(data: data, encoding: .utf8) else {
            throw PushCredentialStoreError.invalidStoredCredential
        }
        return credential
    }

    public func generateAndStoreCredential(for sourceID: UUID) async throws -> String {
        let credential = PushCredentialGenerator.make()
        try await deleteCredential(for: sourceID)
        var query = baseQuery(sourceID)
        query[kSecValueData as String] = Data(credential.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PushCredentialStoreError.keychain(status) }
        return credential
    }

    public func deleteCredential(for sourceID: UUID) async throws {
        let status = SecItemDelete(baseQuery(sourceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PushCredentialStoreError.keychain(status) }
    }

    private func baseQuery(_ sourceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sourceID.uuidString,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
    }
}

public enum PushCredentialGenerator {
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
