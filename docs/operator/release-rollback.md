# The Bridge — Release Rollback Runbook (Distribution D1)

**When to use:** a `v*` release was published (`release.yml` ran on a tag push) and the
build is bad — regressed, crashing, or shipping something that must not reach users.
This is the *consolidated* rollback procedure; deep failure-mode tables live in
[`docs/release/sparkle-troubleshooting.md`](../release/sparkle-troubleshooting.md).

## The kill-switch, in one sentence
`SUFeedURL` = `https://raw.githubusercontent.com/KUP-IP/the-bridge/main/appcast.xml`, so
**whatever `appcast.xml` says on `main` is what every installed app is offered.** Reverting
that file to the last-good item stops the bad update from being handed out — no new build required.

---

## 1 · Stop the bleed — revert the appcast on `main` (fastest, do this first)
The bad release's CI committed a new top `<item>` to `appcast.xml` (`release(vX.Y.Z): publish
Sparkle appcast … [skip ci]`). Revert it so the newest advertised item is the **last-good** version:

```sh
git fetch origin main && git switch main && git pull
git revert --no-edit <appcast-commit-sha>     # the release(vX.Y.Z) commit
git push origin main
```
- Reverting restores a **previously CI-signed** appcast item, so the `edSignature` / `length` stay
  valid — never hand-edit the signature (breaks Sparkle verification).
- **Propagation:** `raw.githubusercontent.com` has a short CDN TTL (~5 min); rollback is fast but
  not instant. The app sends `Cache-Control: no-cache`, so once the CDN refreshes, clients see the
  last-good version and stop offering the bad one.
- Users **already mid-download** of the bad DMG aren't stopped by this — see step 2.

## 2 · Pull the bad artifact (defense in depth)
Remove the enclosure so even a cached feed can't complete the bad download:
```sh
gh release delete vX.Y.Z --yes            # or: gh release edit vX.Y.Z --draft
gh release delete-asset vX.Y.Z the-bridge-vX.Y.Z.dmg   # if keeping the release page
```
Deleting the DMG makes the enclosure URL 404 — the exact "update failure dialog" case in
`sparkle-troubleshooting.md` (a hard stop, not a silent bad install).

## 3 · Verify the feed is back to last-good
```sh
make verify-sparkle-feed        # check_appcast_version.sh + verify_sparkle_feed.sh
```
Confirm: newest `sparkle:shortVersionString` / `sparkle:version` = the last-good version, feed
returns 200, and the enclosure DMG resolves 200 with a matching `Content-Length`.

## 4 · If the bad build crash-loops on launch
That's the staged-update SPM-bundle corruption mode, not a feed problem. The shipped
graceful-degradation guard means the app **boots with an SF Symbol icon** rather than
crash-looping; full manual recovery (clear Sparkle staging + `make install-copy`) is in
[`sparkle-troubleshooting.md` § "Manual recovery (operator)"](../release/sparkle-troubleshooting.md).

## 5 · Re-cut a fixed release
- Fix forward, bump `CFBundleVersion` (+ marketing per the versioning rule), land on `main`.
- **Push a NEW tag** (e.g. `vX.Y.(Z+1)`) — never reuse or move the bad tag; Sparkle keys off
  `sparkle:version` (build number), and clients that cached the bad build won't re-offer the same one.
- Do **not** hand-build the DMG/appcast — let `release.yml` sign both (byte-identical ed25519).

---

## Pre-publish safeguard — dry-run (prevents most rollbacks)
`release.yml` supports a **dry-run** via `workflow_dispatch` (`dry_run: true`): it builds, signs,
notarizes, and runs the full appcast-vs-DMG verification (URL + byte-length + deterministic
edSignature) **without** publishing the release or committing the appcast.
```sh
gh workflow run release.yml -f dry_run=true -f release_tag=vX.Y.Z
```
Run this before the real tag whenever a release touches signing, entitlements, or the bundle
layout. **Prerequisite:** the Apple Developer legal agreement must be signed or notarization 403s
(see `docs/operator/v4-release-gate.md` § 0) — until then a dry-run fails at the notarize step.

## What is NOT a rollback (know the difference)
- **"You're up to date" / no dialog** — appcast `sparkle:version` ≤ installed build. Not a failure.
- **Feed 404** — repo went private or `SUFeedURL` wrong. Fix hosting, not the release.
