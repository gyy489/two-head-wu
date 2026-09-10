import Foundation
import Security

// Retained across the public Air naming migration so an enrolled device never
// silently creates a second hardware identity.
private let applicationTag = Data("com.twoheadwu.member-air.v2".utf8)
private let spkiPrefix = Data([
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
])

private enum MemberKeyError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

private func privateKey() throws -> SecKey {
    let query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: applicationTag,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecReturnRef as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let key = result else {
        throw MemberKeyError.message("member Secure Enclave key is unavailable")
    }
    return (key as! SecKey)
}

private func createKey() throws -> SecKey {
    if let existing = try? privateKey() { return existing }
    var accessError: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        [.privateKeyUsage],
        &accessError
    ) else {
        throw MemberKeyError.message("cannot create device-only key access control")
    }
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
        kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
        kSecPrivateKeyAttrs as String: [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrAccessControl as String: access,
        ],
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
        throw MemberKeyError.message("Secure Enclave P-256 key creation failed")
    }
    var exportError: Unmanaged<CFError>?
    if SecKeyCopyExternalRepresentation(key, &exportError) != nil {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag,
        ] as CFDictionary)
        throw MemberKeyError.message("refusing an exportable private key")
    }
    return key
}

private func publicKeyBase64(_ key: SecKey) throws -> String {
    guard let publicKey = SecKeyCopyPublicKey(key) else {
        throw MemberKeyError.message("member public key is unavailable")
    }
    var error: Unmanaged<CFError>?
    guard let external = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
        throw MemberKeyError.message("member public key export failed")
    }
    guard external.count == 65, external.first == 0x04 else {
        throw MemberKeyError.message("member public key is not uncompressed P-256")
    }
    return (spkiPrefix + external).base64EncodedString()
}

private func checkedSigningInput(_ encoded: String) throws -> Data {
    guard let data = Data(base64Encoded: encoded), data.count <= 65_536,
          let text = String(data: data, encoding: .utf8),
          text.hasPrefix("TWO-HEAD-WU-MEMBER-V2\n") || text.hasPrefix("TWO-HEAD-WU-MEMBER-ENROLL-V2\n") else {
        throw MemberKeyError.message("signing input is not a member protocol message")
    }
    return data
}

private func sign(inputBase64: String) throws -> String {
    let input = try checkedSigningInput(inputBase64)
    let key = try privateKey()
    let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
    guard SecKeyIsAlgorithmSupported(key, .sign, algorithm) else {
        throw MemberKeyError.message("Secure Enclave does not support P-256/SHA-256 signing")
    }
    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(key, algorithm, input as CFData, &error) as Data? else {
        throw MemberKeyError.message("member request signing failed")
    }
    return signature.base64EncodedString()
}

private func deleteKey() throws {
    let status = SecItemDelete([
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: applicationTag,
    ] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw MemberKeyError.message("member Secure Enclave key deletion failed")
    }
}

private func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

do {
    let command = CommandLine.arguments.dropFirst().first ?? ""
    switch command {
    case "create":
        let key = try createKey()
        try emit(["provider": "secure-enclave", "public_key_spki_base64": try publicKeyBase64(key)])
    case "public":
        let key = try privateKey()
        try emit(["provider": "secure-enclave", "public_key_spki_base64": try publicKeyBase64(key)])
    case "sign":
        guard let input = option("--input-base64") else {
            throw MemberKeyError.message("sign requires --input-base64")
        }
        try emit(["algorithm": "ecdsa-p256-sha256-der", "signature_base64": try sign(inputBase64: input)])
    case "delete":
        try deleteKey()
        try emit(["deleted": true])
    default:
        throw MemberKeyError.message("usage: member-key create|public|sign --input-base64 VALUE|delete")
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(2)
}
