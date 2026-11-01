import Foundation

/// happy-app encryptBlob: nonce(24) || secretbox MAC(16) || ciphertext.
public enum BlobCipher {
    /// What comes before the ciphertext: the nonce, then the MAC.
    public static let headerLength = SecretBox.nonceLength + SecretBox.macLength

    public static func sessionKey(dataKey: Data) -> Data {
        KeyTree.deriveKey(master: dataKey, usage: "Happy Blobs", path: ["session"])
    }
    public static func seal(_ data: Data, key: Data, random: RandomSource = SystemRandom()) throws -> Data {
        try SecretBox.sealBundle(data, key: key, random: random)
    }
    public static func open(_ data: Data, key: Data) -> Data? {
        SecretBox.openBundle(data, key: key)
    }

    /// The plaintext of ciphertext bytes that start `offset` bytes into a
    /// bundle's plaintext, before its MAC can be checked. XSalsa20 is a
    /// stream cipher, so any range decrypts on its own: the keystream is
    /// read from `32 + offset` (secretbox keeps its first 32 bytes for the
    /// Poly1305 key). Nothing here is authenticated: whoever reads it must
    /// `open` the whole bundle before keeping it.
    public static func decrypt(range ciphertext: Data, nonce: Data, key: Data, offset: Int) -> Data? {
        guard key.count == SecretBox.keyLength, nonce.count == SecretBox.nonceLength, offset >= 0 else { return nil }
        var buffer = [UInt8](ciphertext)
        Salsa20.xsalsa20XOR(&buffer, key: key, nonce: nonce, skip: 32 + offset)
        return Data(buffer)
    }
}
