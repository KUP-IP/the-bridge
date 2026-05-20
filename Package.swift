// swift-tools-version: 6.2
// PKT-318: Added swift-nio for SSE transport on :9700
// NOTE: Tests use a custom executable harness (not XCTest). Run via: swift run NotionBridgeTests
// PKT-353: Platform bumped to macOS 26 (Tahoe) for Liquid Glass adoption.
//   swift-tools-version bumped 6.0 → 6.2 (required for .macOS(.v26)).
// PKT-430: Added Sparkle for auto-update framework
// PKT-551: Added NotificationContentExtension executable target. Built as a
//   standalone binary and packaged into a .appex bundle by the Makefile
//   (SPM does not natively support .appExtension targets).
// PKT-800 S2: Added JWTKit 5.5.0 (vapor/jwt-kit, swift-tools 6.0, pure-Swift
//   swift-crypto — no vendored BoringSSL) for RFC 7515/7517 JWS+JWKS bearer
//   validation on the remote /mcp connector path. Pinned to a stable line
//   that builds cleanly under the Swift 6.2 toolchain on macOS 26.
import PackageDescription

let package = Package(
    name: "NotionBridge",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NotionBridge", targets: ["NotionBridge"]),
        .executable(name: "NotionBridgeTests", targets: ["NotionBridgeTests"]),
        .executable(name: "NotificationContentExtension", targets: ["NotificationContentExtension"]),
        .executable(name: "NBJobRunner", targets: ["NBJobRunner"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", exact: "5.5.0"),
    ],
    targets: [
        .target(
            name: "NotionBridgeLib",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "JWTKit", package: "jwt-kit"),
            ],
            path: "NotionBridge",
            exclude: ["App/NotionBridgeApp.swift", "App/Resources"],
            // W3: bundled default SKILL.md files (Apache-2.0 skills from
            // anthropics/skills + STUB.md stubs for source-available
            // skills we cannot redistribute). `.copy` preserves directory
            // layout verbatim so `Bundle.module` exposes
            // `skills/<name>/SKILL.md` 1:1 — SPM does not try to
            // "compile" the .md files.
            resources: [.copy("Resources/skills")]
        ),
        .executableTarget(
            name: "NotionBridge",
            dependencies: ["NotionBridgeLib"],
            path: "NotionBridge/App",
            exclude: ["AppDelegate.swift", "StatusBarController.swift", "WindowTracker.swift"],
            sources: ["NotionBridgeApp.swift"],
            resources: [.process("Resources")]
        ),
        // Standalone test executable (not .testTarget) — uses custom test harness
        // in main.swift instead of XCTest. Run via: swift run NotionBridgeTests
        .executableTarget(
            name: "NotionBridgeTests",
            dependencies: ["NotionBridgeLib",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                // PKT-800 S2 (fix #4b): NIOHTTP1 + NIOCore are used directly
                // by RemoteOAuthHTTPTests (NIOEmbedded request-part decode)
                // and RemoteOAuthBearerTests; make the dependency explicit
                // rather than relying on transitive NIOEmbedded re-export.
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio")
            ],
            path: "NotionBridgeTests"
        ),
        // PKT-551: Notification Content Extension — built as a standalone
        // executable, then repackaged by the Makefile into
        // NotificationContentExtension.appex and embedded into
        // Notion Bridge.app/Contents/PlugIns/.
        // Info.plist for the .appex lives at NotificationContentExtension/Info.plist
        // and is copied by `make extension`, not built by SPM.
        .executableTarget(
            name: "NotificationContentExtension",
            path: "NotificationContentExtension",
            exclude: ["Info.plist"],
            sources: ["NotificationViewController.swift"]
        ),
        // v1.9.2: Signed launchd callback helper. Replaces /usr/bin/curl in
        // job plists so BTM groups background items under Notion Bridge.
        .executableTarget(
            name: "NBJobRunner",
            path: "NBJobRunner",
            sources: ["main.swift"]
        ),
    ]
)