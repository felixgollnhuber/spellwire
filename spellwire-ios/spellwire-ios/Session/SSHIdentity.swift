import Crypto
import Foundation
import Security
@preconcurrency import NIOSSH

nonisolated private enum SSHIdentityPersistenceError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Security framework error \(status)"
        }
    }
}

nonisolated struct SSHDeviceIdentityMetadata: Codable, Hashable, Sendable {
    let publicKeyOpenSSH: String
    let publicKeyFingerprintSHA256: String
    let createdAt: Date
}

nonisolated struct SSHDeviceIdentity: Hashable, Sendable {
    let metadata: SSHDeviceIdentityMetadata
    let rawPrivateKey: Data

    func clientIdentity(username: String) throws -> SSHClientIdentity {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
        return SSHClientIdentity(
            username: username,
            privateKey: NIOSSHPrivateKey(ed25519Key: privateKey)
        )
    }
}

nonisolated struct SSHClientIdentity: Sendable {
    let username: String
    let privateKey: NIOSSHPrivateKey
}

nonisolated struct SSHIdentityStore {
    private struct StoredIdentity: Codable {
        let rawPrivateKey: Data
        let createdAt: Date
    }

    private let service = "\(Bundle.main.bundleIdentifier ?? "xyz.floritzmaier.spellwire-ios").device-ed25519"
    private let account = "spellwire-device-key"

    func loadOrCreateIdentity() throws -> SSHDeviceIdentity {
        if let stored = try loadStoredIdentity() {
            return try materializeIdentity(from: stored)
        }

        let privateKey = Curve25519.Signing.PrivateKey()
        let stored = StoredIdentity(rawPrivateKey: privateKey.rawRepresentation, createdAt: .now)
        try save(stored)
        return try materializeIdentity(from: stored)
    }

    func deleteIdentity() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHIdentityPersistenceError.unexpectedStatus(status)
        }
    }

    private func loadStoredIdentity() throws -> StoredIdentity? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try JSONDecoder().decode(StoredIdentity.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw SSHIdentityPersistenceError.unexpectedStatus(status)
        }
    }

    private func save(_ identity: StoredIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        let query = baseQuery()
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var createQuery = query
            createQuery[kSecValueData as String] = data
            let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
            guard createStatus == errSecSuccess else {
                throw SSHIdentityPersistenceError.unexpectedStatus(createStatus)
            }
        default:
            throw SSHIdentityPersistenceError.unexpectedStatus(updateStatus)
        }
    }

    private func materializeIdentity(from stored: StoredIdentity) throws -> SSHDeviceIdentity {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: stored.rawPrivateKey)
        let publicKeyOpenSSH = SSHKeyFormatting.openSSHPublicKey(for: Data(privateKey.publicKey.rawRepresentation))
        return SSHDeviceIdentity(
            metadata: SSHDeviceIdentityMetadata(
                publicKeyOpenSSH: publicKeyOpenSSH,
                publicKeyFingerprintSHA256: SSHKeyFormatting.sha256Fingerprint(for: publicKeyOpenSSH),
                createdAt: stored.createdAt
            ),
            rawPrivateKey: stored.rawPrivateKey
        )
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

nonisolated enum SSHKeyFormatting {
    static func openSSHPublicKey(for rawPublicKey: Data) -> String {
        let algorithm = "ssh-ed25519"
        let blob = sshString(Data(algorithm.utf8)) + sshString(rawPublicKey)
        return "\(algorithm) \(blob.base64EncodedString()) spellwire-ios"
    }

    static func sha256Fingerprint(for openSSHKey: String) -> String {
        let blob = openSSHBlob(from: openSSHKey) ?? Data(openSSHKey.utf8)
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }

    static func openSSHBlob(from openSSHKey: String) -> Data? {
        let components = openSSHKey.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }
        return Data(base64Encoded: String(components[1]))
    }

    private static func sshString(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        data.append(payload)
        return data
    }
}
