// license-cli — Packet B (PRJCT-2754 · Ship The Bridge v4, Wave 1)
//
// Operator CLI for the Ed25519 license-token system. It reuses the app's
// LicenseToken.encode / verify (from TheBridgeLib), so a token minted here is
// byte-for-byte what the shipped app verifies — the CLI and the in-app
// verifier can never drift.
//
//   swift run license-cli keygen
//       → prints a fresh Ed25519 keypair (private + public, base64url).
//
//   swift run license-cli mint --private <b64url> --id ord_123 \
//         --sub buyer@example.com --kind paid [--days 365 | --exp <unix>]
//       → prints a signed license token for that buyer.
//
//   swift run license-cli verify --token <token> [--public <b64url>]
//       → verifies against the given public key, or — if --public is omitted —
//         the key compiled into THIS build via LicensePublicKey.bundled().
//         Prints the entitled payload.
//
// SECURITY: the PRIVATE key is the operator's signing secret — never commit
// it, never paste it where it will be logged. See
// docs/operator/license-ops-runbook.md.

import Foundation
import CryptoKit
import TheBridgeLib

// MARK: - tiny arg parsing

func optValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(2)
}

let usage = """
license-cli — Ed25519 license tokens for The Bridge

USAGE:
  license-cli keygen
  license-cli mint --private <b64url> --id <id> --sub <email> --kind paid|grandfather [--days N | --exp <unix>]
  license-cli verify --token <token> [--public <b64url>]
"""

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { print(usage); exit(0) }
let rest = Array(argv.dropFirst())

switch cmd {
case "keygen":
    let priv = Curve25519.Signing.PrivateKey()
    let privB64 = LicenseToken.base64url(priv.rawRepresentation)
    let pubB64 = LicenseToken.base64url(priv.publicKey.rawRepresentation)
    print("# Ed25519 license keypair — store the PRIVATE key in operator custody; NEVER commit it.")
    print("private \(privB64)")
    print("public  \(pubB64)")
    print("")
    print("# Inject the PUBLIC key into a build:")
    print("#   make build LICENSE_PUBLIC_KEY_BASE64URL=\(pubB64)")
    print("# (release.yml reads it from the LICENSE_PUBLIC_KEY_BASE64URL repo secret.)")

case "mint":
    guard let privB64 = optValue("--private", in: rest) else { fail("mint requires --private <b64url>") }
    guard let id = optValue("--id", in: rest) else { fail("mint requires --id <id>") }
    guard let sub = optValue("--sub", in: rest) else { fail("mint requires --sub <email>") }
    let kind = optValue("--kind", in: rest) ?? "paid"
    guard kind == "paid" || kind == "grandfather" else { fail("--kind must be 'paid' or 'grandfather'") }
    guard let privRaw = LicenseToken.base64urlDecode(privB64),
          let priv = try? Curve25519.Signing.PrivateKey(rawRepresentation: privRaw) else {
        fail("--private is not a valid base64url Ed25519 private key")
    }
    let now = Int64(Date().timeIntervalSince1970)
    var exp: Int64?
    if let expStr = optValue("--exp", in: rest) {
        guard let e = Int64(expStr) else { fail("--exp must be a unix timestamp (seconds)") }
        exp = e
    } else if let daysStr = optValue("--days", in: rest) {
        guard let d = Int64(daysStr), d > 0 else { fail("--days must be a positive integer") }
        exp = now + d * 86_400
    }
    let payload = LicenseTokenPayload(id: id, sub: sub, kind: kind, iat: now, exp: exp)
    do {
        let token = try LicenseToken.encode(payload: payload, signedBy: priv)
        print(token)
    } catch {
        fail("failed to encode token: \(error)")
    }

case "verify":
    guard let token = optValue("--token", in: rest) else { fail("verify requires --token <token>") }
    let pub: Curve25519.Signing.PublicKey
    if let pubB64 = optValue("--public", in: rest) {
        guard let raw = LicenseToken.base64urlDecode(pubB64),
              let k = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            fail("--public is not a valid base64url Ed25519 public key")
        }
        pub = k
    } else if let bundled = LicensePublicKey.bundled() {
        pub = bundled
    } else {
        fail("no --public given and this build has no bundled key (inject LICENSE_PUBLIC_KEY_BASE64URL at build, or pass --public)")
    }
    do {
        let payload = try LicenseToken.verify(token, publicKey: pub)
        print("✅ valid license token")
        print("  id   \(payload.id)")
        print("  sub  \(payload.sub)")
        print("  kind \(payload.kind)")
        print("  iat  \(payload.iat)")
        print("  exp  \(payload.exp.map(String.init) ?? "none")")
    } catch {
        fail("INVALID: \(error.localizedDescription)")
    }

default:
    print(usage)
    exit(cmd == "-h" || cmd == "--help" ? 0 : 2)
}
