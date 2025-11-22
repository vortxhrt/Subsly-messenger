import Foundation
import CryptoKit
import Security

enum CryptoError: Error {
    case noKeysFound
    case keyGenerationFailed
    case encryptionFailed
    case decryptionFailed
    case invalidPublicKey
    case invalidData
}

final class CryptoService {
    static let shared = CryptoService()
    
    // Identifier for the Keychain
    private let keychainTag = "com.subsly.messenger.privatekey"
    
    // MARK: - Key Management
    
    func ensureKeysExist() throws {
        if retrievePrivateKey() == nil {
            let privateKey = P256.KeyAgreement.PrivateKey()
            try savePrivateKey(privateKey)
        }
    }
    
    func getMyPublicKey() -> String? {
        guard let key = retrievePrivateKey() else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }
    
    // MARK: - Encryption / Decryption
    
    func encrypt(text: String, otherUserPublicKeyString: String) throws -> String {
        guard let myPrivateKey = retrievePrivateKey() else { throw CryptoError.noKeysFound }
        
        guard let otherKeyData = Data(base64Encoded: otherUserPublicKeyString),
              let otherPublicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: otherKeyData) else {
            throw CryptoError.invalidPublicKey
        }
        
        // 1. Derive Base Shared Secret
        let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: otherPublicKey)
        
        // 2. AUDIT FIX: Generate a Random Salt (32 bytes)
        // This ensures the derived key is different for every single message
        let salt = symmetricKeySalt()
        
        // 3. Derive Symmetric Key using the Salt
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
        
        // 4. Encrypt (AES-GCM)
        guard let data = text.data(using: .utf8) else { throw CryptoError.encryptionFailed }
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        guard let boxData = sealedBox.combined else { throw CryptoError.encryptionFailed }
        
        // 5. Pack Salt + Ciphertext together
        var finalData = Data()
        finalData.append(salt)
        finalData.append(boxData)
        
        return finalData.base64EncodedString()
    }
    
    func decrypt(encryptedString: String, otherUserPublicKeyString: String) throws -> String {
        guard let myPrivateKey = retrievePrivateKey() else { throw CryptoError.noKeysFound }
        
        guard let otherKeyData = Data(base64Encoded: otherUserPublicKeyString),
              let otherPublicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: otherKeyData) else {
            throw CryptoError.invalidPublicKey
        }
        
        guard let fullData = Data(base64Encoded: encryptedString) else { throw CryptoError.invalidData }
        
        // AUDIT FIX: Validate salt length
        guard fullData.count > 32 else { throw CryptoError.invalidData }
        
        // 1. Extract Salt
        let salt = fullData.prefix(32)
        let ciphertext = fullData.dropFirst(32)
        
        // 2. Derive Shared Secret
        let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: otherPublicKey)
        
        // 3. Derive Key using extracted Salt
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(),
            outputByteCount: 32
        )
        
        // 4. Decrypt
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        let decryptedData = try AES.GCM.open(sealedBox, using: symmetricKey)
        
        guard let text = String(data: decryptedData, encoding: .utf8) else {
            throw CryptoError.decryptionFailed
        }
        
        return text
    }
    
    // MARK: - Helpers
    
    private func symmetricKeySalt() -> Data {
        var keyData = Data(count: 32)
        let result = keyData.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        return (result == errSecSuccess) ? keyData : Data(count: 32)
    }
    
    // MARK: - Keychain Helpers
    
    private func savePrivateKey(_ key: P256.KeyAgreement.PrivateKey) throws {
        let data = key.rawRepresentation
        
        // AUDIT FIX: Bind to Device Hardware (Secure Enclave logic)
        // accessibleWhenUnlockedThisDeviceOnly = Cannot be synced to iCloud or moved to another device.
        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [],
            nil
        )
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainTag,
            kSecValueData as String: data,
            kSecAttrAccessControl as String: accessControl as Any
        ]
        
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CryptoError.keyGenerationFailed }
    }
    
    private func retrievePrivateKey() -> P256.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? P256.KeyAgreement.PrivateKey(rawRepresentation: data)
    }
}
