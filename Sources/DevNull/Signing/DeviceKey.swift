import CryptoKit
import Foundation
import Security

/// The Ed25519 key this Mac signs every API request with. It never leaves the Keychain: the web approves its
/// fingerprint as one of the user's devices, and signing out forgets it.
struct DeviceKey {
    private static let service = "sh.dev-null.mac"
    private static let account = "device-key"

    let privateKey: Curve25519.Signing.PrivateKey

    /// The key in the Keychain, or a new one saved there.
    static func loadOrCreate() throws -> DeviceKey {
        if let existing = load() {
            return existing
        }

        let key = DeviceKey(privateKey: Curve25519.Signing.PrivateKey())
        try key.save()

        return key
    }

    static func load() -> DeviceKey? {
        #if DEBUG
            // The preview never touches the real device key.
            if Preview.isEnabled { return nil }
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
        else {
            return nil
        }

        return DeviceKey(privateKey: privateKey)
    }

    static func delete() {
        #if DEBUG
            if Preview.isEnabled { return }
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        SecItemDelete(query as CFDictionary)
    }

    private func save() throws {
        #if DEBUG
            if Preview.isEnabled { return }
        #endif

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: privateKey.rawRepresentation,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// The public key in the SSH wire format: string "ssh-ed25519", string key.
    var publicKeyBlob: Data {
        var blob = Data()
        blob.appendSSHString(Data("ssh-ed25519".utf8))
        blob.appendSSHString(privateKey.publicKey.rawRepresentation)

        return blob
    }

    /// The fingerprint `ssh-keygen -l` prints, which the web shows the user to approve: SHA256:<base64, no padding>.
    var fingerprint: String {
        let digest = Data(SHA256.hash(data: publicKeyBlob))

        return "SHA256:" + digest.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Signs a message as `ssh-keygen -Y sign -n <namespace>` would, in the SSHSIG format, base64 on a single line.
    ///
    /// See https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.sshsig
    func sign(_ message: Data, namespace: String) throws -> String {
        let hashAlgorithm = "sha512"
        let messageHash = Data(SHA512.hash(data: message))

        var signedData = Data("SSHSIG".utf8)
        signedData.appendSSHString(Data(namespace.utf8))
        signedData.appendSSHString(Data())
        signedData.appendSSHString(Data(hashAlgorithm.utf8))
        signedData.appendSSHString(messageHash)

        let rawSignature = try privateKey.signature(for: signedData)

        var signatureBlob = Data()
        signatureBlob.appendSSHString(Data("ssh-ed25519".utf8))
        signatureBlob.appendSSHString(rawSignature)

        var blob = Data("SSHSIG".utf8)
        blob.appendUInt32(1)
        blob.appendSSHString(publicKeyBlob)
        blob.appendSSHString(Data(namespace.utf8))
        blob.appendSSHString(Data())
        blob.appendSSHString(Data(hashAlgorithm.utf8))
        blob.appendSSHString(signatureBlob)

        return blob.base64EncodedString()
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendSSHString(_ value: Data) {
        appendUInt32(UInt32(value.count))
        append(value)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// base64url without padding, as PKCE uses it.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
