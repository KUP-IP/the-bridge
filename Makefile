# Makefile – The Bridge
# PKT-329: V1-14b Build System + Connection Setup
# PKT-346: V1-QUALITY-POLISH — Added install and clean-tcc targets
#
# Standard workflow: make clean → make test → make app → make dmg → make release
# Debug workflow:    make debug
# Dev app bundle:    make app (unsigned, for local testing)

APP_NAME        = The Bridge
DMG_VOLUME_NAME = The Bridge
BUNDLE_ID       = kup.solutions.notion-bridge
BINARY_NAME     = TheBridge
BUILD_DIR       = .build
RELEASE_DIR     = $(BUILD_DIR)/release
DEBUG_DIR       = $(BUILD_DIR)/debug
APP_BUNDLE      = $(BUILD_DIR)/TheBridge.app
FRAMEWORKS_DIR  = $(APP_BUNDLE)/Contents/Frameworks
# PKT-551: Notification Content Extension (.appex) paths
PLUGINS_DIR     = $(APP_BUNDLE)/Contents/PlugIns
EXT_NAME        = NotificationContentExtension
EXT_SRC_DIR     = NotificationContentExtension
EXT_APPEX       = $(PLUGINS_DIR)/$(EXT_NAME).appex
# v1.9.2: Signed launchd callback helper embedded at Contents/MacOS/NBJobRunner.
JOB_RUNNER_NAME = NBJobRunner
JOB_RUNNER_PATH = $(APP_BUNDLE)/Contents/MacOS/$(JOB_RUNNER_NAME)
VERSION        := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG_NAME        = the-bridge-v$(VERSION).dmg
DMG_PATH        = $(BUILD_DIR)/$(DMG_NAME)
DMG_STAGING     = $(BUILD_DIR)/dmg-staging
DMG_BACKGROUND  = $(BUILD_DIR)/dmg-background.png
APPCAST_PATH   ?= appcast.xml
APPCAST_ARCHIVES_DIR = $(BUILD_DIR)/sparkle-updates
RELEASE_TAG    ?= v$(VERSION)
APPCAST_FEED_URL ?= https://raw.githubusercontent.com/KUP-IP/the-bridge/main/appcast.xml
APPCAST_LINK   ?= https://github.com/KUP-IP/the-bridge/releases
SUFeedURL              = https://raw.githubusercontent.com/KUP-IP/the-bridge/main/appcast.xml
APPCAST_DOWNLOAD_URL_PREFIX ?= https://github.com/KUP-IP/the-bridge/releases/download/$(RELEASE_TAG)/
SIGNING_ID     ?= Developer ID Application: Isaiah Peters (VP24Z9CS22)
NOTARIZE_PROFILE ?= notarytool-profile
GENERATE_APPCAST ?= 1
# Optional path to an exported Sparkle EdDSA private-key file. When EMPTY
# (local default) generate_appcast reads the signing key from the login
# Keychain. When SET, it is passed to generate_appcast via --ed-key-file so the
# appcast can be signed headlessly in CI (the runner has no Keychain key) — the
# key file is written from the SPARKLE_ED_PRIVATE_KEY repo secret. EdDSA
# (ed25519) signing is deterministic, so the file-based path produces a
# byte-identical signature to the Keychain path for the same DMG. Use '-' to
# read the key from stdin. Export the key locally with:
#   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x key.txt
SPARKLE_ED_KEY_FILE ?=

INFO_PLIST      = Info.plist
RESOURCES_DIR   = TheBridge/App/Resources
DMG_ICON        = $(RESOURCES_DIR)/Assets.xcassets/AppIcon.appiconset/icon_512x512.png
SPARKLE_ARTIFACT_DIR = $(BUILD_DIR)/artifacts/sparkle/Sparkle
SPARKLE_FRAMEWORK = $(SPARKLE_ARTIFACT_DIR)/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
SPARKLE_TOOLS_DIR = $(SPARKLE_ARTIFACT_DIR)/bin

.PHONY: debug build test app extension jobrunner appcast dmg dmg-background sign notarize verify verify-sparkle-feed check-update-flow check-appcast release clean install install-copy install-agent-safe clean-tcc patch-deps check-stale-build

# ── Debug Build ────────────────────────────────────────────────
debug:
	@echo "🔨 Building debug binary..."
	swift build -c debug
	@echo "✅ Debug build: $(DEBUG_DIR)/$(BINARY_NAME)"

# ── Release Build ──────────────────────────────────────────────
build:
	@echo "🔨 Building release binary with strict concurrency..."
	swift build -c release \
		-Xswiftc -strict-concurrency=complete
	@echo "$(CURDIR)" > $(BUILD_DIR)/.source_path
	@echo "✅ Release build: $(RELEASE_DIR)/$(BINARY_NAME)"

# ── Test ───────────────────────────────────────────────────────
test:
	@echo "🧪 Running test suite..."
	swift build -c debug
	$(DEBUG_DIR)/TheBridgeTests
	@echo "✅ Tests complete"

# WS-C (PKT-798) → v3.0·0.5 → Dev-suite audit → PKT-800 S1 → S2 → S3 → S4
# → cmd-w2 (Commands data layer) → cmd-w4 (fetch_skill /markdown switch)
# → cu-sa (fetch_skill simplified `properties` map, 2026-05-18): runs the
# suite + asserts the green floor (1195 as of 2026-05-19: prior 1204 net
# −9 from Sprint A's deprecated-tool removals losing their tests; tool
# count 162 → 172. Sprint A — Phase 2 mcp-builder consolidation: top-15
# audit items shipped (12 structural, 3 description-only markers
# flagged for Phase 2.5), idempotentHint annotation added as 4th axis
# with new audit-invariant. Floor lowered per recorded decision in
# scripts/test-floor-gate.sh per the order-inversion rule. Worktree
# impl + independent review + 3 nit fixes + orchestrator
# gate; measured on main; provenance in scripts/test-floor-gate.sh) and
# zero failures.
# Used by CI so a shrunk/disabled suite fails. Floor provenance lives in
# scripts/test-floor-gate.sh.
test-floor:
	./scripts/test-floor-gate.sh

# ── App Bundle (.app) ──────────────────────────────────────────
app: build extension jobrunner
	@echo "📦 Packaging .app bundle..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@mkdir -p $(FRAMEWORKS_DIR)
	@cp $(RELEASE_DIR)/$(BINARY_NAME) "$(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)"
	@install_name_tool -add_rpath "@loader_path/../Frameworks" "$(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)"
	@cp $(INFO_PLIST) $(APP_BUNDLE)/Contents/Info.plist
	@test -f $(RESOURCES_DIR)/TheBridge.icns && \
		cp $(RESOURCES_DIR)/TheBridge.icns $(APP_BUNDLE)/Contents/Resources/ || true
	@for f in $(RESOURCES_DIR)/*.png; do \
		test -f "$$f" && cp "$$f" $(APP_BUNDLE)/Contents/Resources/ || true; \
	done
	@# ── Copy SPM resource bundle to Contents/Resources (where Bundle.module expects it) ──
	@SPM_BUNDLE="$(RELEASE_DIR)/TheBridge_TheBridge.bundle"; \
		if [ -d "$$SPM_BUNDLE" ]; then \
			cp -R "$$SPM_BUNDLE" "$(APP_BUNDLE)/Contents/Resources/"; \
			echo "  ↳ Copied SPM resource bundle (TheBridge) to Contents/Resources"; \
		fi
	@# ── Copy TheBridgeLib resource bundle too (3.3.0 W3: bundled SKILL.md ──
	@# ── skills declared in Package.swift on the TheBridgeLib target — its  ──
	@# ── Bundle.module lookup needs the sibling library-target bundle).        ──
	@LIB_BUNDLE="$(RELEASE_DIR)/TheBridge_TheBridgeLib.bundle"; \
		if [ -d "$$LIB_BUNDLE" ]; then \
			cp -R "$$LIB_BUNDLE" "$(APP_BUNDLE)/Contents/Resources/"; \
			echo "  ↳ Copied SPM resource bundle (TheBridgeLib — bundled skills) to Contents/Resources"; \
		fi
	@# ── Add MenuBarIcon-named copies for image(forResource:) lookup ──
	@if [ -f "$(APP_BUNDLE)/Contents/Resources/TheBridge_TheBridge.bundle/thebridge-menubar.png" ]; then \
		cp "$(APP_BUNDLE)/Contents/Resources/TheBridge_TheBridge.bundle/thebridge-menubar.png" \
			"$(APP_BUNDLE)/Contents/Resources/TheBridge_TheBridge.bundle/MenuBarIcon.png"; \
		cp "$(APP_BUNDLE)/Contents/Resources/TheBridge_TheBridge.bundle/thebridge-menubar@2x.png" \
			"$(APP_BUNDLE)/Contents/Resources/TheBridge_TheBridge.bundle/MenuBarIcon@2x.png"; \
		echo "  ↳ Added MenuBarIcon.png + @2x aliases"; \
	fi
	@# ── Copy MenuBarIcon to top-level Contents/Resources for Bundle.main fallback ──
	@if [ -f "$(APP_BUNDLE)/Contents/Resources/thebridge-menubar.png" ]; then \
		cp "$(APP_BUNDLE)/Contents/Resources/thebridge-menubar.png" \
			"$(APP_BUNDLE)/Contents/Resources/MenuBarIcon.png"; \
		cp "$(APP_BUNDLE)/Contents/Resources/thebridge-menubar@2x.png" \
			"$(APP_BUNDLE)/Contents/Resources/MenuBarIcon@2x.png"; \
		echo "  ↳ Added top-level MenuBarIcon.png + @2x for Bundle.main"; \
	fi
	@# ── Compile Assets.xcassets → Assets.car via actool ──
	@XCASSETS="$(APP_BUNDLE)/Contents/Resources/TheBridge_TheBridge.bundle/Assets.xcassets"; \
		if [ -d "$$XCASSETS" ]; then \
			actool --compile "$(APP_BUNDLE)/Contents/Resources/TheBridge_TheBridge.bundle" \
				--platform macosx --minimum-deployment-target 14.0 \
				--app-icon AppIcon --output-partial-info-plist /dev/null \
				"$$XCASSETS" >/dev/null 2>&1 && \
			echo "  ↳ Compiled Assets.xcassets → Assets.car" || \
			echo "  ⚠️  actool compile failed (menu bar icon may use fallback)"; \
			rm -rf "$$XCASSETS"; \
			echo "  ↳ Cleaned raw .xcassets from bundle"; \
		fi
	@# ── Compile AppIcon from source .xcassets into main Contents/Resources for Notification Center ──
	@SRC_XCASSETS="$(RESOURCES_DIR)/Assets.xcassets"; \
		if [ -d "$$SRC_XCASSETS" ]; then \
			actool --compile "$(APP_BUNDLE)/Contents/Resources" \
				--platform macosx --minimum-deployment-target 14.0 \
				--app-icon AppIcon --output-partial-info-plist /dev/null \
				"$$SRC_XCASSETS" >/dev/null 2>&1 && \
			echo "  ↳ Compiled AppIcon into main Contents/Resources" || \
			echo "  ⚠️  actool AppIcon compile failed"; \
		fi
	@if [ -d "$(SPARKLE_FRAMEWORK)" ]; then \
		cp -R "$(SPARKLE_FRAMEWORK)" "$(FRAMEWORKS_DIR)/"; \
		echo "  ↳ Embedded Sparkle.framework"; \
	else \
		echo "  ⚠️  Sparkle.framework not found at $(SPARKLE_FRAMEWORK)"; \
	fi
	@# PKT-551: Embed Notification Content Extension (.appex)
	@echo "🔔 Embedding $(EXT_NAME).appex into $(PLUGINS_DIR)..."
	@mkdir -p $(EXT_APPEX)/Contents/MacOS
	@cp $(RELEASE_DIR)/$(EXT_NAME) $(EXT_APPEX)/Contents/MacOS/$(EXT_NAME)
	@cp $(EXT_SRC_DIR)/Info.plist $(EXT_APPEX)/Contents/Info.plist
	@echo "  ↳ Embedded $(EXT_NAME).appex"
	@# v1.9.2: Embed NBJobRunner helper into Contents/MacOS/
	@echo "🔗 Embedding $(JOB_RUNNER_NAME) into Contents/MacOS/..."
	@cp $(RELEASE_DIR)/$(JOB_RUNNER_NAME) "$(JOB_RUNNER_PATH)"
	@chmod +x "$(JOB_RUNNER_PATH)"
	@echo "  ↳ Embedded $(JOB_RUNNER_NAME)"
	@echo "✅ App bundle: $(APP_BUNDLE)"

# ── Notification Content Extension (.appex) ───────────────
# PKT-551: Builds the extension binary via SPM. The Makefile app target
# repackages it into .appex structure and embeds it into PlugIns/.
extension:
	@echo "🔨 Building $(EXT_NAME) binary..."
	swift build -c release --product $(EXT_NAME)
	@echo "✅ Extension binary: $(RELEASE_DIR)/$(EXT_NAME)"

# ── NBJobRunner helper binary (v1.9.2) ──
# Builds the signed launchd callback helper. Replaces /usr/bin/curl in job
# plists so macOS BTM attributes background items to The Bridge.
jobrunner:
	@echo "🔨 Building $(JOB_RUNNER_NAME) binary..."
	swift build -c release --product $(JOB_RUNNER_NAME)
	@echo "✅ JobRunner binary: $(RELEASE_DIR)/$(JOB_RUNNER_NAME)"

# ── Stale-build guard ──────────────────────────────────────────────────
# Runs BEFORE build so it reads the path from the *previous* build.
# If the source directory was renamed since last build, aborts with a
# clear message rather than installing a Bundle.module-crash binary.
check-stale-build:
	@if [ -f "$(BUILD_DIR)/.source_path" ] && [ "$$(cat $(BUILD_DIR)/.source_path)" != "$(CURDIR)" ]; then \
		echo "❌ Stale build detected."; \
		echo "   Built from: $$(cat $(BUILD_DIR)/.source_path)"; \
		echo "   Current:    $(CURDIR)"; \
		echo "   SPM bakes the build path into Bundle.module — run 'make clean' first."; \
		exit 1; \
	fi

# ── Local-install safety (2026-06-04 incident) ─────────────────────────
# `install`/`install-copy` write directly into the Sparkle-managed
# /Applications bundle. If the app is running or Sparkle has a staged update
# pending, the manual rm-rf+ditto can race Sparkle's installer and leave a
# corrupted bundle (mixed versions) that crash-loops at launch in
# Bundle.module / loadMenuBarIcon(). These canned recipes make local installs
# race-safe: quit the app + clear pending Sparkle staging before writing, and
# verify bundle consistency after. (The shipped DMG is unaffected — the `app`
# target packages the SPM resource bundle correctly.)
define PREINSTALL_SAFETY
@echo "⏏️  Quitting any running $(APP_NAME) (prevents install/Sparkle race)..."
@osascript -e 'tell application "The Bridge" to quit' >/dev/null 2>&1 || true
@pkill -f "The Bridge.app/Contents/MacOS/TheBridge" 2>/dev/null || true
@pkill -f "NBJobRunner" 2>/dev/null || true
@i=0; while pgrep -f "The Bridge.app/Contents/MacOS/TheBridge" >/dev/null 2>&1 && [ $$i -lt 20 ]; do sleep 0.5; i=$$((i+1)); done
@echo "🧹 Clearing any pending Sparkle staged update (prevents revert-over-install)..."
@rm -rf "$$HOME/Library/Caches/$(BUNDLE_ID)/org.sparkle-project.Sparkle/Installation/"* "$$HOME/Library/Caches/$(BUNDLE_ID)/org.sparkle-project.Sparkle/PersistentDownloads/"* 2>/dev/null || true
endef

define VERIFY_INSTALL
@SRC_VER=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null); \
	DST_VER=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "/Applications/The Bridge.app/Contents/Info.plist" 2>/dev/null); \
	if [ -z "$$DST_VER" ] || [ "$$SRC_VER" != "$$DST_VER" ]; then \
		echo "❌ install verify: version mismatch (source '$$SRC_VER' != installed '$$DST_VER') — bundle may be raced/corrupt"; exit 1; \
	fi; \
	if [ ! -d "/Applications/The Bridge.app/Contents/Resources/TheBridge_TheBridge.bundle" ]; then \
		echo "❌ install verify: SPM resource bundle missing — app would crash at launch (Bundle.module)"; exit 1; \
	fi; \
	echo "✅ install verify: version $$DST_VER + SPM resource bundle present"
endef

# ── Install ────────────────────────────────────────────────────────────
# PKT-1 v3.5: destination renamed to "/Applications/The Bridge.app".
# Cleanup removes the new path AND both legacy variants ("The Bridge.app"
# from 3.x display-name installs, "TheBridge.app" from any executable-
# name installs) so re-installs land cleanly regardless of prior state.
install: check-stale-build notarize
	@echo "📲 Installing notarized app to /Applications..."
	$(PREINSTALL_SAFETY)
	@rm -rf "/Applications/The Bridge.app" "/Applications/The Bridge.app" "/Applications/TheBridge.app"
	@ditto "$(APP_BUNDLE)" "/Applications/The Bridge.app"
	@spctl --assess --verbose "/Applications/The Bridge.app"
	@echo "🔄 Re-registering with Launch Services..."
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "/Applications/The Bridge.app"
	@killall Dock 2>/dev/null || true
	$(VERIFY_INSTALL)
	@echo "✅ Installed: /Applications/The Bridge.app"

# v1.7.0: Copy-only install (no notarize dep, no killall) (F3)
install-copy: check-stale-build sign
	@echo "⚠️  install-copy replaces the Sparkle-managed /Applications/The Bridge.app — the running app is quit automatically below to avoid an install/Sparkle race."
	@echo "Installing app to /Applications (copy-only)..."
	$(PREINSTALL_SAFETY)
	@rm -rf "/Applications/The Bridge.app" "/Applications/The Bridge.app" "/Applications/TheBridge.app"
	@ditto "$(APP_BUNDLE)" "/Applications/The Bridge.app"
	@echo "🔄 Re-registering with Launch Services..."
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "/Applications/The Bridge.app"
	$(VERIFY_INSTALL)
	@echo "Installed: /Applications/The Bridge.app"
	@echo "Restart The Bridge manually to pick up changes."

# Alias for agents / remote MCP sessions: same as install-copy (no notarize; does not kill The Bridge).
install-agent-safe: install-copy

# ── Clean TCC ──────────────────────────────────────────────────────────
clean-tcc:
	@echo "🧹 Resetting TCC for legacy bundle ID (solutions.kup.keepr)..."
	-tccutil reset All solutions.kup.keepr
	@echo "🧹 Resetting TCC for current bundle ID (kup.solutions.notion-bridge)..."
	-tccutil reset All kup.solutions.notion-bridge
	@echo "✅ TCC reset complete — permissions will be re-requested on next launch"

# ── Appcast ───────────────────────────────────────────────────
appcast:
	@command -v "$(SPARKLE_TOOLS_DIR)/generate_appcast" >/dev/null || { echo "❌ Sparkle generate_appcast tool not found"; exit 1; }
	@test -f "$(DMG_PATH)" || { echo "❌ DMG not found at $(DMG_PATH). Run 'make dmg' or build the DMG first."; exit 1; }
	@echo "📰 Generating appcast..."
	@rm -rf "$(APPCAST_ARCHIVES_DIR)"
	@rm -f "$(APPCAST_PATH)"
	@mkdir -p "$(APPCAST_ARCHIVES_DIR)"
	@cp "$(DMG_PATH)" "$(APPCAST_ARCHIVES_DIR)/"
	@"$(SPARKLE_TOOLS_DIR)/generate_appcast" \
		$(if $(SPARKLE_ED_KEY_FILE),--ed-key-file "$(SPARKLE_ED_KEY_FILE)",) \
		--download-url-prefix "$(APPCAST_DOWNLOAD_URL_PREFIX)" \
		--link "$(APPCAST_LINK)" \
		-o "$(APPCAST_PATH)" \
		"$(APPCAST_ARCHIVES_DIR)"
	@rm -rf "$(APPCAST_ARCHIVES_DIR)"
	@echo "✅ Appcast: $(APPCAST_PATH)"

# ── DMG Background ────────────────────────────────────────────
dmg-background:
	@mkdir -p $(BUILD_DIR)
	@python3 scripts/generate_dmg_background.py "$(DMG_BACKGROUND)" "$(DMG_ICON)"
	@echo "🎨 DMG background: $(DMG_BACKGROUND)"

# ── DMG (disk image) ──────────────────────────────────────────
dmg: notarize dmg-background
	@command -v create-dmg >/dev/null || { echo "❌ create-dmg is required. Install it with: brew install create-dmg"; exit 1; }
	@echo "💿 Creating production DMG..."
	@rm -rf $(DMG_STAGING)
	@mkdir -p $(DMG_STAGING)
	@cp -R "$(APP_BUNDLE)" "$(DMG_STAGING)/"
	@rm -f "$(DMG_PATH)"
	create-dmg \
		--volname "$(DMG_VOLUME_NAME)" \
		--volicon "$(RESOURCES_DIR)/TheBridge.icns" \
		--background "$(DMG_BACKGROUND)" \
		--window-pos 220 140 \
		--window-size 640 360 \
		--text-size 14 \
		--icon-size 128 \
		--icon "$(notdir $(APP_BUNDLE))" 180 180 \
		--hide-extension "$(notdir $(APP_BUNDLE))" \
		--app-drop-link 460 180 \
		--format UDZO \
		"$(DMG_PATH)" \
		"$(DMG_STAGING)"
	@rm -rf $(DMG_STAGING)
	@echo "🔏 Signing DMG..."
	codesign --force --sign "$(SIGNING_ID)" --timestamp "$(DMG_PATH)"
	@echo "📤 Notarizing DMG..."
	xcrun notarytool submit "$(DMG_PATH)" --keychain-profile "$(NOTARIZE_PROFILE)" --wait
	@echo "📎 Stapling DMG..."
	xcrun stapler staple "$(DMG_PATH)"
	@echo "🔍 Verifying DMG..."
	spctl --assess --type open --context context:primary-signature --verbose "$(DMG_PATH)"
	@if [ "$(GENERATE_APPCAST)" = "1" ]; then \
		$(MAKE) appcast RELEASE_TAG="$(RELEASE_TAG)" APPCAST_PATH="$(APPCAST_PATH)" APPCAST_DOWNLOAD_URL_PREFIX="$(APPCAST_DOWNLOAD_URL_PREFIX)" APPCAST_LINK="$(APPCAST_LINK)" SPARKLE_ED_KEY_FILE="$(SPARKLE_ED_KEY_FILE)"; \
	fi
	@echo "✅ DMG: $(DMG_PATH)"

# ── Sign ───────────────────────────────────────────────────────
sign: app
	@echo "🔏 Signing app bundle..."
	@if [ -d "$(FRAMEWORKS_DIR)" ]; then \
		find "$(FRAMEWORKS_DIR)" \( -name "*.framework" -o -name "*.dylib" \) -maxdepth 1 | while read framework; do \
			codesign --force --deep --options runtime --timestamp --sign "$(SIGNING_ID)" "$$framework"; \
			echo "  ↳ Signed $$(basename "$$framework")"; \
		done; \
	fi
	@# PKT-551: Sign nested .appex BEFORE parent app
	@if [ -d "$(EXT_APPEX)" ]; then \
		codesign --force --options runtime --timestamp --sign "$(SIGNING_ID)" "$(EXT_APPEX)"; \
		echo "  ↳ Signed $(EXT_NAME).appex (nested)"; \
	fi
	codesign --force --deep --sign "$(SIGNING_ID)" \
		--entitlements TheBridge.entitlements \
		--options runtime \
		--timestamp \
		$(APP_BUNDLE)
	@echo "🔍 Verifying codesign (deep/strict)..."
	@codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)
	@echo "✅ Signed"

# ── Notarize ───────────────────────────────────────────────────
notarize: sign
	@echo "📤 Submitting for notarization..."
	ditto -c -k --keepParent $(APP_BUNDLE) $(BUILD_DIR)/TheBridge.zip
	xcrun notarytool submit $(BUILD_DIR)/TheBridge.zip \
		--keychain-profile "$(NOTARIZE_PROFILE)" \
		--wait
	xcrun stapler staple $(APP_BUNDLE)
	@echo "✅ Notarized"

# ── Verify ─────────────────────────────────────────────────────
verify:
	@echo "🔍 Verification..."
	codesign --verify --deep --verbose $(APP_BUNDLE)
	spctl --assess --verbose $(APP_BUNDLE) || echo "⚠️  spctl may require notarization"
	@echo "✅ Verified"

# ── Sparkle feed (public availability) ─────────────────────────
check-update-flow:
	@echo "🔄 Verifying update flow..."
	@REMOTE_BUILD=$$(curl -s $(SUFeedURL) | grep -o '<sparkle:version>[0-9]*' | head -1 | grep -o '[0-9]*'); \
	LOCAL_BUILD=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $(INFO_PLIST)); \
	echo "  Remote appcast build: $$REMOTE_BUILD"; \
	echo "  Local bundle build:   $$LOCAL_BUILD"; \
	if [ -n "$$REMOTE_BUILD" ] && [ "$$REMOTE_BUILD" != "$$LOCAL_BUILD" ]; then \
		echo "  ⚠️  Appcast build ($$REMOTE_BUILD) != local build ($$LOCAL_BUILD)"; \
	else \
		echo "  ✅ Build numbers match"; \
	fi

check-appcast:
	@chmod +x scripts/check_appcast_version.sh
	@./scripts/check_appcast_version.sh "$(INFO_PLIST)" "$(APPCAST_PATH)"

verify-sparkle-feed: check-appcast
	@chmod +x scripts/verify_sparkle_feed.sh
	@./scripts/verify_sparkle_feed.sh "$(INFO_PLIST)"

# ── Release (full pipeline) ────────────────────────────────────
release: clean test dmg verify
	@echo "🚀 Release complete: $(DMG_PATH)"

# ── Clean ──────────────────────────────────────────────────────
clean:
	@echo "🧹 Cleaning..."
	swift package clean
	@rm -rf $(APP_BUNDLE) $(DMG_STAGING)
	@rm -f $(BUILD_DIR)/*.zip $(BUILD_DIR)/*.dmg
	@echo "✅ Clean"

# ── Patch Dependencies (Swift 6.3 compat) ─────────────────────
# Workaround: MCP swift-sdk v0.11.0 has #SendingRisksDataRace errors
# under Swift 6.3 strict concurrency. This creates a local editable
# override with Swift 5 language mode for the MCP target.
# Ref: github.com/swiftlang/swift/issues/87523
patch-deps:
	@echo "🔧 Patching swift-sdk for Swift 6.3 compatibility..."
	@if [ ! -d "Packages/swift-sdk" ]; then \
		swift package edit swift-sdk; \
	fi
	@sed -i '' '/swiftSettings: \[/{ n; s|.*|                .swiftLanguageMode(.v5), // Swift 6.3 compat — #SendingRisksDataRace|; }' \
		Packages/swift-sdk/Package.swift
	@echo "✅ swift-sdk patched (swiftLanguageMode .v5)"
