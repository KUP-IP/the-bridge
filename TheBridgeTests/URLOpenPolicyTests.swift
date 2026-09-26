// URLOpenPolicyTests.swift — #312 hermetic allowlist + shell-open detector

import Foundation
import TheBridgeLib

func runURLOpenPolicyTests() async {
    print("\n🔗 URLOpenPolicy Tests")

    await test("URLOpenPolicy accepts http(s) and notion URLs") {
        for raw in [
            "https://www.notion.so/28acbb58889e80d5b111ed23b996c304",
            "http://127.0.0.1:9700/health",
            "notion://www.notion.so/page",
            "  HTTPS://www.notion.so/keep  "
        ] {
            switch URLOpenPolicy.parse(raw) {
            case .success(let url):
                try expect(URLOpenPolicy.allowedSchemes.contains(url.scheme?.lowercased() ?? ""))
            case .failure(let error):
                throw TestError.assertion("expected success for \(raw), got \(error)")
            }
        }
    }

    await test("URLOpenPolicy rejects file, javascript, relative, and credentialed URLs") {
        let rejected = [
            "",
            "   ",
            "www.notion.so/page",
            "file:///tmp/secret.txt",
            "javascript:alert(1)",
            "data:text/html,hi",
            "https://user:pass@example.com/x",
            "https:///"
        ]
        for raw in rejected {
            switch URLOpenPolicy.parse(raw) {
            case .success(let url):
                throw TestError.assertion("expected rejection for \(raw), got \(url)")
            case .failure:
                break
            }
        }
    }

    await test("URLOpenPolicy detects shell open of remote URLs only") {
        let remote = [
            "open https://www.notion.so/page",
            "open 'https://www.notion.so/page'",
            "/usr/bin/open https://example.com",
            "open -a Safari https://www.notion.so/page",
            "cd /tmp && open https://www.notion.so/page",
            "open notion://www.notion.so/page"
        ]
        for command in remote {
            try expect(
                URLOpenPolicy.shellCommandOpensRemoteURL(command),
                "expected remote-open detection for \(command)"
            )
        }

        let notRemote = [
            "open /tmp/file.txt",
            "open .",
            "open README.md",
            "echo open https://www.notion.so/page",
            "ls https://www.notion.so/page",
            "open file:///tmp/x"
        ]
        for command in notRemote {
            try expect(
                !URLOpenPolicy.shellCommandOpensRemoteURL(command),
                "did not expect remote-open detection for \(command)"
            )
        }
    }
}
