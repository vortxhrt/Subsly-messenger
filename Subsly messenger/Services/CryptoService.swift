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
    
    /// Generates a new Private/Public key pair if one doesn't exist in Keychain.
    func ensureKeysExist() throws {
        if retrievePrivateKey() == nil {
            let privateKey = P256.KeyAgreement.PrivateKey()
            try savePrivateKey(privateKey)
        }
    }
    
    /// Returns the Public Key as a Base64 string to be saved in Firestore.
    func getMyPublicKey() -> String? {
        guard let key = retrievePrivateKey() else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }
    
    // MARK: - Encryption / Decryption
    
    /// Encrypts text using the current user's Private Key + the Recipient's Public Key.
    func encrypt(text: String, otherUserPublicKeyString: String) throws -> String {
        guard let myPrivateKey = retrievePrivateKey() else { throw CryptoError.noKeysFound }
        
        // 1. Reconstruct the other user's Public Key
        guard let otherKeyData = Data(base64Encoded: otherUserPublicKeyString),
              let otherPublicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: otherKeyData) else {
            throw CryptoError.invalidPublicKey
        }
        
        // 2. Derive Shared Secret (ECDH)
        let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: otherPublicKey)
        
        // 3. Derive Symmetric Key (HKDF)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(), // In a simple 1:1 implementation, static salt is acceptable if keys rotate, but here keys are static.
            sharedInfo: Data(),
            outputByteCount: 32
        )
        
        // 4. Encrypt (AES-GCM)
        guard let data = text.data(using: .utf8) else { throw CryptoError.encryptionFailed }
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        
        // 5. Return combined data (Nonce + Ciphertext + Tag) as Base64
        return sealedBox.combined?.base64EncodedString() ?? ""
    }
    
    /// Decrypts ciphertext using the current user's Private Key + the Sender's Public Key.
    func decrypt(encryptedString: String, otherUserPublicKeyString: String) throws -> String {
        guard let myPrivateKey = retrievePrivateKey() else { throw CryptoError.noKeysFound }
        
        guard let otherKeyData = Data(base64Encoded: otherUserPublicKeyString),
              let otherPublicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: otherKeyData) else {
            throw CryptoError.invalidPublicKey
        }
        
        // 1. Derive the SAME Shared Secret
        let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: otherPublicKey)
        
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        
        // 2. Decrypt
        guard let data = Data(base64Encoded: encryptedString) else { throw CryptoError.invalidData }
        
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let decryptedData = try AES.GCM.open(sealedBox, using: symmetricKey)
        
        guard let text = String(data: decryptedData, encoding: .utf8) else {
            throw CryptoError.decryptionFailed
        }
        
        return text
    }
    
    // MARK: - Keychain Helpers
    
    private func savePrivateKey(_ key: P256.KeyAgreement.PrivateKey) throws {
        let data = key.rawRepresentation
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainTag,
            kSecValueData as String: data
        ]
        
        // Delete existing item if present
        SecItemDelete(query as CFDictionary)
        
        // Add new item
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
