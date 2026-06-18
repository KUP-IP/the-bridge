// LicenseCLITests.swift — Packet B (PRJCT-2754 · Ship The Bridge v4, Wave 1)
//
// Proves the license loop end-to-end with a DEV keypair: a token minted with
// LicenseToken.encode (the SAME call `license-cli mint` uses) verifies and
// resolves to .licensed (entitled). Also locks the build-injection seam's
// fail-closed default so a forgotten key injection can never silently accept
// a license.

import Foundation
import CryptoKit
import TheBridgeLib

func runLicenseCLITests() async {
    print("\n\u{1F511} Packet B — license pubkey injection + mint→verify→entitled")

    await test("Packet B: injection seam is fail-closed by default (no bundled key)") {
        // The COMMITTED LicensePublicKeyInjected.swift must ship empty so an
        // unconfigured build verifies no token. make / release.yml inject it.
        try expect(LicensePublicKey.bundledBase64URL.isEmpty,
                   "committed build must ship an empty bundled key (fail-closed)")
        try expect(LicensePublicKey.bundled() == nil,
                   "empty injection must yield a nil bundled key (no token verifies)")
    }

    await test("Packet B: a non-empty injected key decodes through the bundled() path") {
        // Simulate what `make inject-license-key` compiles in: feed a real
        // base64url public key through the SAME decode path bundled() uses.
        let priv = Curve25519.Signing.PrivateKey()
        let pubB64 = LicenseToken.base64url(priv.publicKey.rawRepresentation)
        guard let raw = LicenseToken.base64urlDecode(pubB64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw TestError.assertion("injected base64url key failed to decode")
        }
        try expect(key.rawRepresentation == priv.publicKey.rawRepresentation,
                   "decoded injected key must equal the original public key")
    }

    await test("Packet B: mint → verify round-trip with a dev keypair") {
        let priv = Curve25519.Signing.PrivateKey()
        let payload = LicenseTokenPayload(id: "ord_devtest", sub: "dev@kup.solutions",
                                          kind: "paid", iat: 1_750_000_000, exp: nil)
        let token = try LicenseToken.encode(payload: payload, signedBy: priv)        // `mint`
        let back = try LicenseToken.verify(token, publicKey: priv.publicKey)         // `verify`
        try expect(back == payload, "round-tripped payload must equal the minted payload")
    }

    await test("Packet B: a token signed by the WRONG key is rejected (forgery)") {
        let priv = Curve25519.Signing.PrivateKey()
        let attacker = Curve25519.Signing.PrivateKey()
        let payload = LicenseTokenPayload(id: "ord_forge", sub: "x@y.z", kind: "paid",
                                          iat: 1_750_000_000, exp: nil)
        let token = try LicenseToken.encode(payload: payload, signedBy: attacker)
        do {
            _ = try LicenseToken.verify(token, publicKey: priv.publicKey)
            throw TestError.assertion("expected badSignature, but verify succeeded")
        } catch let e as LicenseVerifyError {
            try expect(e == .badSignature, "expected .badSignature, got \(e)")
        }
    }

    await test("Packet B: dev-minted token resolves to .licensed (entitled)") {
        // The activation outcome the gate cares about: a verified token →
        // entitled. Uses the pure status derivation (no disk) so it is
        // hermetic; LicenseManagerTests covers the actor activate()+persist path.
        let priv = Curve25519.Signing.PrivateKey()
        let payload = LicenseTokenPayload(id: "ord_devtest", sub: "dev@kup.solutions",
                                          kind: "paid", iat: 1_750_000_000, exp: nil)
        let token = try LicenseToken.encode(payload: payload, signedBy: priv)
        let verified = try LicenseToken.verify(token, publicKey: priv.publicKey)
        let state = LicenseState(firstLaunchAt: 0,
                                 token: LicenseState.StoredToken(raw: token, payload: verified))
        let status = LicenseManager.computeStatus(state: state) {
            Date(timeIntervalSince1970: 1_750_000_100)
        }
        if case .licensed(let p) = status {
            try expect(p.id == "ord_devtest", "expected ord_devtest, got \(p.id)")
        } else {
            throw TestError.assertion("expected .licensed, got \(status)")
        }
    }

    await test("Packet B: an expired dev-minted token resolves to .licenseExpired") {
        let priv = Curve25519.Signing.PrivateKey()
        let payload = LicenseTokenPayload(id: "ord_exp", sub: "dev@kup.solutions",
                                          kind: "paid", iat: 1_700_000_000, exp: 1_700_100_000)
        let token = try LicenseToken.encode(payload: payload, signedBy: priv)
        let verified = try LicenseToken.verify(token, publicKey: priv.publicKey)
        let state = LicenseState(firstLaunchAt: 0,
                                 token: LicenseState.StoredToken(raw: token, payload: verified))
        let status = LicenseManager.computeStatus(state: state) {
            Date(timeIntervalSince1970: 1_700_200_000)   // past exp
        }
        if case .licenseExpired = status { /* ok */ } else {
            throw TestError.assertion("expected .licenseExpired, got \(status)")
        }
    }
}
