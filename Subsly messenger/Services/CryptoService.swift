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
    
    // UPDATED: Changed to .v2 to force all devices to regenerate fresh keys
    // This fixes the "decryption failed/gibberish" issue caused by stale keys.
    private let keychainTag = "com.subsly.messenger.privatekey.v2"
    
    // MARK: - Key Management
    
    func ensureKeysExist() throws {
        // If key doesn't exist, generate one based on the environment
        if retrievePrivateKey() == nil {
            #if targetEnvironment(simulator)
            // SIMULATOR: Use Standard Software Key (Secure Enclave doesn't exist here)
            let privateKey = P256.KeyAgreement.PrivateKey()
            try savePrivateKey(privateKey)
            #else
            // REAL DEVICE: Use Hardware Secure Enclave Key (Audit Compliant)
            let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
            try savePrivateKey(privateKey)
            #endif
        }
    }
    
    func getMyPublicKey() -> String? {
        // Retrieve raw key bytes based on environment type
        #if targetEnvironment(simulator)
        guard let key = retrievePrivateKey() as? P256.KeyAgreement.PrivateKey else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
        #else
        guard let key = retrievePrivateKey() as? SecureEnclave.P256.KeyAgreement.PrivateKey else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
        #endif
    }
    
    // MARK: - Encryption / Decryption
    
    func encrypt(text: String, otherUserPublicKeyString: String) throws -> String {
        guard let otherKeyData = Data(base64Encoded: otherUserPublicKeyString),
              let otherPublicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: otherKeyData) else {
            throw CryptoError.invalidPublicKey
        }
        
        // 1. Derive Shared Secret (Environment specific)
        let sharedSecret: SharedSecret
        
        #if targetEnvironment(simulator)
        guard let myKey = retrievePrivateKey() as? P256.KeyAgreement.PrivateKey else { throw CryptoError.noKeysFound }
        sharedSecret = try myKey.sharedSecretFromKeyAgreement(with: otherPublicKey)
        #else
        guard let myKey = retrievePrivateKey() as? SecureEnclave.P256.KeyAgreement.PrivateKey else { throw CryptoError.noKeysFound }
        sharedSecret = try myKey.sharedSecretFromKeyAgreement(with: otherPublicKey)
        #endif
        
        // 2. Generate Random Salt (32 bytes)
        let salt = symmetricKeySalt()
        
        // 3. Derive Symmetric Key using Salt
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
        
        // 5. Pack Salt + Ciphertext
        var finalData = Data()
        finalData.append(salt)
        finalData.append(boxData)
        
        return finalData.base64EncodedString()
    }
    
    func decrypt(encryptedString: String, otherUserPublicKeyString: String) throws -> String {
        guard let otherKeyData = Data(base64Encoded: otherUserPublicKeyString),
              let otherPublicKey = try? P256.KeyAgreement.PublicKey(rawRepresentation: otherKeyData) else {
            throw CryptoError.invalidPublicKey
        }
        
        guard let fullData = Data(base64Encoded: encryptedString), fullData.count > 32 else {
            throw CryptoError.invalidData
        }
        
        // 1. Extract Salt
        let salt = fullData.prefix(32)
        let ciphertext = fullData.dropFirst(32)
        
        // 2. Derive Shared Secret (Environment specific)
        let sharedSecret: SharedSecret
        
        #if targetEnvironment(simulator)
        guard let myKey = retrievePrivateKey() as? P256.KeyAgreement.PrivateKey else { throw CryptoError.noKeysFound }
        sharedSecret = try myKey.sharedSecretFromKeyAgreement(with: otherPublicKey)
        #else
        guard let myKey = retrievePrivateKey() as? SecureEnclave.P256.KeyAgreement.PrivateKey else { throw CryptoError.noKeysFound }
        sharedSecret = try myKey.sharedSecretFromKeyAgreement(with: otherPublicKey)
        #endif
        
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
        if result != errSecSuccess {
            fatalError("Critical Security Failure: OS Random Number Generator failed.")
        }
        return keyData
    }
    
    // MARK: - Keychain Helpers
    
    // Returns Any? because type differs between Simulator (Software) and Device (Hardware)
    private func retrievePrivateKey() -> Any? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        
        #if targetEnvironment(simulator)
        return try? P256.KeyAgreement.PrivateKey(rawRepresentation: data)
        #else
        return try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
        #endif
    }
    
    private func savePrivateKey(_ key: Any) throws {
        let data: Data
        let accessControl: Any?
        
        #if targetEnvironment(simulator)
        // Simulator: Software key, no strict access control
        guard let k = key as? P256.KeyAgreement.PrivateKey else { throw CryptoError.keyGenerationFailed }
        data = k.rawRepresentation
        accessControl = nil
        #else
        // Real Device: Hardware key handle + Strict Access Control
        guard let k = key as? SecureEnclave.P256.KeyAgreement.PrivateKey else { throw CryptoError.keyGenerationFailed }
        data = k.dataRepresentation
        accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [],
            nil
        )
        #endif
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainTag,
            kSecValueData as String: data
        ]
        
        if let ac = accessControl {
            query[kSecAttrAccessControl as String] = ac
        }
        
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CryptoError.keyGenerationFailed }
    }
}
