// LicensePublicKeyInjected.swift — Packet B (PRJCT-2754 · Ship The Bridge v4, Wave 1)
// TheBridge · Core · Licensing
//
// ⚠️ GENERATED / BUILD-INJECTED — do not hand-edit.
//
// `make inject-license-key` rewrites the single constant below from the
// LICENSE_PUBLIC_KEY_BASE64URL environment variable at build time:
//   • local dev      →  a DEV public key, so a locally-built binary can
//                        activate dev-minted tokens (testing / demos).
//   • release.yml CI →  the PRODUCTION public key, read from the
//                        LICENSE_PUBLIC_KEY_BASE64URL repository secret.
//
// The COMMITTED default below is the EMPTY string = FAIL-CLOSED: an
// unconfigured build verifies NO token (LicensePublicKey.bundled() == nil),
// so a forgotten key injection can never silently accept a license.
//
// The matching Ed25519 PRIVATE key is NEVER stored in this repo. Mint tokens
// with `swift run license-cli mint …` under operator custody
// (docs/operator/license-ops-runbook.md).

import Foundation

extension LicensePublicKey {
    /// Build-time injected, base64url-encoded raw 32-byte Ed25519 public key.
    /// Empty = fail-closed (no bundled key). Overwritten at build time.
    static let injectedBase64URL = ""   // INJECT:LICENSE_PUBLIC_KEY — do not hand-edit
}
