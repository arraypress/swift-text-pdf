//
//  Crypto.swift
//  TextPDF
//
//  Created by David Sherlock on 2026.
//
//  AES-256 encryption, revision 6 — ISO 32000-2, §7.6.4.
//
//  One mode, and deliberately one. The older revisions are here to be refused:
//  RC4-40 falls to a laptop in seconds, RC4-128 is not much better, and
//  AES-128 exists for readers from 2005. Offering them would be offering a
//  choice whose wrong answers look identical to the right one.
//
//  ## What this does and does not protect
//
//  The document cannot be opened without the password: every stream — the
//  page contents, the fonts, the images, anything attached — is encrypted,
//  and so is every string.
//
//  It is exactly as strong as the password. The common workflow for this
//  feature is a payslip keyed to a date of birth or a national insurance
//  number, and those are guessed offline in about as long as it takes to read
//  this paragraph. That satisfies a policy; it is not secrecy. Secrecy is a
//  link behind authentication, or a key exchanged somewhere other than the
//  covering email.
//
//  ## What is deliberately missing
//
//  There is no owner password and there are no permission flags. "Printing
//  not allowed" is enforced only by readers that feel like it, and stripping
//  the flags is one command with tools anybody has. A feature whose whole
//  effect is a belief is worse than not having it.
//

import CommonCrypto
import CryptoKit
import Foundation

/// The standard security handler, at revision 6.
struct Encryption {

    /// The key everything in the file is encrypted with.
    let fileKey: Data

    /// The `/Encrypt` dictionary, written unencrypted as the specification
    /// requires — it is what tells a reader how to decrypt the rest.
    let dictionary: String

    /// Sets up encryption for a password.
    ///
    /// - Returns: `nil` when the password is empty. A document encrypted with
    ///   nothing is a document that opens with a return key, and that is a
    ///   worse outcome than an unencrypted one, which at least does not
    ///   claim to be protected.
    /// Why this password cannot be used, if it cannot.
    ///
    /// One rule, and it is not about strength: the password must be ASCII.
    /// The specification says a revision 6 password is UTF-8, and this writes
    /// it that way — but PDFKit, which is what Preview and most Mac software
    /// read PDFs with, encodes a non-ASCII password the way revision 4 did
    /// and then cannot open the file. CoreGraphics opens it; Preview does
    /// not. A password that works in one reader and not the one your
    /// recipient has is worse than being told to pick another.
    static func problem(with password: String) -> String? {
        guard !password.isEmpty else { return nil }

        guard password.allSatisfy({ $0.isASCII }) else {
            return "The password has characters outside ASCII in it. The format allows them, "
                + "but PDFKit — which is Preview, and most Mac software — cannot open a file "
                + "locked with one, so the person you send it to may not be able to either."
        }
        return nil
    }

    init?(password: String) {
        // Normalised and then cut to 127 bytes, which is what the
        // specification says a reader will do to whatever somebody types —
        // so a longer password that this accepted whole would hash to
        // something no reader could reproduce, and the document would refuse
        // its own password.
        let secret = Data(password.precomposedStringWithCanonicalMapping.utf8.prefix(127))
        guard !secret.isEmpty else { return nil }

        // The file key is random and never derived from the password: the
        // password unlocks the key, so changing it later would not mean
        // re-encrypting the document.
        var key = Data(count: 32)
        var validationSalt = Data(count: 8)
        var keySalt = Data(count: 8)
        Encryption.fill(&key)
        Encryption.fill(&validationSalt)
        Encryption.fill(&keySalt)

        self.fileKey = key

        // Algorithm 8: the user entries. /U proves a password is right; /UE
        // carries the file key, wrapped in a key derived from that password.
        let userHash = Encryption.hardened(password: secret, salt: validationSalt, extra: Data())
        let user = userHash + validationSalt + keySalt

        let userKey = Encryption.hardened(password: secret, salt: keySalt, extra: Data())
        let wrapped = Encryption.aes(key: userKey, iv: Data(count: 16), data: key,
                                     encrypt: true, padded: false)

        // Algorithm 9: the owner entries. There is no separate owner password
        // here, so it is the same one — which is the honest arrangement,
        // because an owner password exists to grant permissions this does not
        // implement.
        var ownerValidation = Data(count: 8)
        var ownerKeySalt = Data(count: 8)
        Encryption.fill(&ownerValidation)
        Encryption.fill(&ownerKeySalt)

        let ownerHash = Encryption.hardened(password: secret, salt: ownerValidation, extra: user)
        let owner = ownerHash + ownerValidation + ownerKeySalt

        let ownerKey = Encryption.hardened(password: secret, salt: ownerKeySalt, extra: user)
        let ownerWrapped = Encryption.aes(key: ownerKey, iv: Data(count: 16), data: key,
                                          encrypt: true, padded: false)

        // Algorithm 10. Everything is allowed: the flags are advisory and this
        // does not pretend otherwise, so the file says so rather than
        // asserting a restriction no reader has to honour.
        let permissions: Int32 = -1
        var perms = Data()
        withUnsafeBytes(of: permissions.littleEndian) { perms.append(contentsOf: $0) }
        perms.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        perms.append(contentsOf: Array("Tadb".utf8))
        var noise = Data(count: 4)
        Encryption.fill(&noise)
        perms.append(noise)

        let permsEncrypted = Encryption.aes(key: key, iv: Data(), data: perms,
                                            encrypt: true, padded: false, ecb: true)

        self.dictionary = "<</Filter /Standard /V 5 /R 6 /Length 256 "
            + "/CF <</StdCF <</CFM /AESV3 /AuthEvent /DocOpen /Length 32>>>> "
            + "/StmF /StdCF /StrF /StdCF "
            + "/U <\(user.hex)> /UE <\(wrapped.hex)> "
            + "/O <\(owner.hex)> /OE <\(ownerWrapped.hex)> "
            + "/P \(permissions) /Perms <\(permsEncrypted.hex)> /EncryptMetadata true>>"
    }

    // MARK: Encrypting content

    /// Encrypts one stream or string, with a fresh initialisation vector.
    ///
    /// The vector is prepended, which is where a reader looks for it. AESV3
    /// uses the file key directly rather than deriving one per object, so
    /// there is nothing to mix in from the object number.
    func encrypt(_ data: Data) -> Data {
        var iv = Data(count: 16)
        Encryption.fill(&iv)
        return iv + Encryption.aes(key: fileKey, iv: iv, data: data, encrypt: true, padded: true)
    }

    // MARK: The hardened hash

    /// Algorithm 2.B — the iterated hash that makes guessing expensive.
    ///
    /// Not a single SHA-256: sixty-four rounds at minimum, each one an AES
    /// pass over sixty-four copies of the password and the running hash, with
    /// the digest chosen by the data itself. That is what stops a password
    /// list being tried at the speed of a hash.
    static func hardened(password: Data, salt: Data, extra: Data) -> Data {
        var k = Data(SHA256.hash(data: password + salt + extra))
        var round = 0
        var e = Data()

        repeat {
            // K1: the password, the running key and the extra data, sixty-four
            // times over.
            var block = Data()
            block.reserveCapacity((password.count + k.count + extra.count) * 64)
            for _ in 0..<64 { block.append(password + k + extra) }

            e = aes(key: k.prefix(16), iv: k.dropFirst(16).prefix(16), data: block,
                    encrypt: true, padded: false)

            // Which digest to use next is decided by the first sixteen bytes
            // of the result, so the sequence cannot be precomputed.
            let choice = e.prefix(16).reduce(0) { ($0 + Int($1)) } % 3
            switch choice {
            case 0: k = Data(SHA256.hash(data: e))
            case 1: k = Data(SHA384.hash(data: e))
            default: k = Data(SHA512.hash(data: e))
            }

            round += 1
        } while round < 64 || Int(e.last ?? 0) > round - 32

        return k.prefix(32)
    }

    // MARK: Primitives

    /// AES, from CommonCrypto — CryptoKit offers GCM and key wrapping but no
    /// CBC, and the specification asks for CBC.
    static func aes(
        key: Data, iv: Data, data: Data,
        encrypt: Bool, padded: Bool, ecb: Bool = false
    ) -> Data {
        let capacity = data.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0

        let status = out.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions((ecb ? kCCOptionECBMode : 0)
                                | (padded ? kCCOptionPKCS7Padding : 0)),
                            keyBytes.baseAddress, key.count,
                            ecb ? nil : ivBytes.baseAddress,
                            input.baseAddress, data.count,
                            output.baseAddress, capacity,
                            &moved
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return Data() }
        return out.prefix(moved)
    }

    /// Random bytes, from the system.
    private static func fill(_ data: inout Data) {
        let count = data.count
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    }
}

extension Data {

    /// The bytes as a PDF hexadecimal string's contents.
    var hex: String { map { String(format: "%02X", $0) }.joined() }
}
