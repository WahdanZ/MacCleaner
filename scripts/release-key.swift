// Release-signing key for Mac Cleaner's in-app updates (Ed25519).
// The private key lives only in your login keychain, never on GitHub.
//
//   swift scripts/release-key.swift init        create the key (once) and print the public key for Updates.swift
//   swift scripts/release-key.swift public      print the public key again
//   swift scripts/release-key.swift sign FILE   write FILE.sig (base64 signature of FILE)
//   swift scripts/release-key.swift verify FILE [SIGFILE] [PUBLIC_KEY]   check a .sig (no keychain needed;
//                                               default key: releasePublicKey in MacCleaner/Updates.swift)
//
// Back the key up: `security find-generic-password -s io.github.wahdanz.maccleaner.release-signing -w`
// prints it; keep it in your password manager. Without it, later releases can't be signed for in-app updates.
import CryptoKit
import Foundation
import Security

let service = "io.github.wahdanz.maccleaner.release-signing"
let account = "ed25519"

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

func loadKey() -> Curve25519.Signing.PrivateKey? {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecAttrAccount as String: account, kSecReturnData as String: true]
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
          let raw = Data(base64Encoded: String(decoding: d, as: UTF8.self)) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func publicKey(_ k: Curve25519.Signing.PrivateKey) -> String { k.publicKey.rawRepresentation.base64EncodedString() }

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "init":
    if let k = loadKey() { print("A release key already exists. Public key:\n\(publicKey(k))"); exit(0) }
    let k = Curve25519.Signing.PrivateKey()
    let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                              kSecAttrAccount as String: account, kSecAttrLabel as String: "Mac Cleaner release signing key",
                              kSecValueData as String: Data(k.rawRepresentation.base64EncodedString().utf8)]
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Couldn't save the key to the keychain (error \(status)).") }
    print("Created the release key in your login keychain. Public key (put it in Updates.swift, releasePublicKey):")
    print(publicKey(k))
    print("\nBack it up now: security find-generic-password -s \(service) -w   → save the output in your password manager.")
case "public":
    guard let k = loadKey() else { fail("No release key. Run: swift scripts/release-key.swift init") }
    print(publicKey(k))
case "sign":
    guard args.count == 2 else { fail("Usage: swift scripts/release-key.swift sign FILE") }
    guard let k = loadKey() else { fail("No release key. Run: swift scripts/release-key.swift init") }
    let file = URL(fileURLWithPath: args[1])
    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { fail("Can't read \(file.path)") }
    let sig = try k.signature(for: data)
    guard k.publicKey.isValidSignature(sig, for: data) else { fail("Signature check failed.") }
    let out = file.appendingPathExtension("sig")
    try Data((sig.base64EncodedString() + "\n").utf8).write(to: out)
    print(out.path)
case "verify":
    // Needs no keychain: checks FILE against FILE.sig (or SIGFILE) with a public key (default: the one in Updates.swift).
    guard args.count >= 2 else { fail("Usage: swift scripts/release-key.swift verify FILE [SIGFILE] [PUBLIC_KEY_BASE64]") }
    let file = URL(fileURLWithPath: args[1])
    let sigFile = URL(fileURLWithPath: args.count > 2 ? args[2] : args[1] + ".sig")
    var pub = args.count > 3 ? args[3] : ""
    if pub.isEmpty {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../MacCleaner/Updates.swift")
        let text = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
        if let line = text.split(separator: "\n").first(where: { $0.contains("static let releasePublicKey") }),
           let q1 = line.firstIndex(of: "\""), let q2 = line[line.index(after: q1)...].firstIndex(of: "\"") {
            pub = String(line[line.index(after: q1)..<q2])
        }
    }
    guard let keyData = Data(base64Encoded: pub), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
        fail("No usable public key.")
    }
    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { fail("Can't read \(file.path)") }
    guard let sigText = try? String(contentsOf: sigFile, encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("Can't read \(sigFile.path)") }
    guard key.isValidSignature(sig, for: data) else { fail("INVALID: \(sigFile.lastPathComponent) is not a signature of \(file.lastPathComponent) by \(pub)") }
    print("valid signature by \(pub)")
default:
    fail("Usage: swift scripts/release-key.swift init | public | sign FILE | verify FILE [SIGFILE] [PUBLIC_KEY]")
}
