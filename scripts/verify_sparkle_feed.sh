#!/usr/bin/env bash
# Verifies the Sparkle update channel is actually deliverable:
#   1. Info.plist SUFeedURL returns HTTP 200 and XML-shaped content (the feed).
#   2. PKT-932: the appcast's <enclosure> DMG URL resolves to HTTP 200 AND the
#      served Content-Length matches the appcast's declared length=.
#
# (2) is the gap that produced the v3.6.0 "Sparkle update failure" dialog: the
# feed advertised a version whose GitHub release asset was missing / wrong-size,
# so Sparkle saw a valid newer version, tried to download, and failed. A
# reachable feed alone does NOT prove an update can complete — the enclosure has
# to be there too. Run this AFTER publishing the release (it hits the live feed).
#
# Usage: from repo root, ./scripts/verify_sparkle_feed.sh [path/to/Info.plist]
set -euo pipefail
PLIST="${1:-Info.plist}"
if [[ ! -f "$PLIST" ]]; then
  echo "❌ Plist not found: $PLIST"
  exit 1
fi
URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST")
echo "📡 SUFeedURL: $URL"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
code=$(curl -fsS -o "$TMP" -w "%{http_code}" "$URL" || true)
if [[ "$code" != "200" ]]; then
  echo "❌ Expected HTTP 200 from appcast URL, got: $code"
  if [[ "$code" == "404" ]]; then
    echo "   Hint: GitHub raw URLs return 404 for private repositories. Use README «Public updates (Sparkle)»: make the repo public, or host appcast.xml on a public HTTPS URL and update SUFeedURL."
  fi
  exit 1
fi
if ! grep -qE '<rss|<\?xml' "$TMP"; then
  echo "❌ Response does not look like XML / Sparkle appcast (first 240 bytes):"
  head -c 240 "$TMP" | cat -v
  echo
  exit 1
fi
echo "✅ Appcast URL is reachable and looks like XML (Sparkle feed)."

# ── PKT-932: enclosure (DMG) deliverability ────────────────────────────────
# Parse the newest <enclosure> from the feed we just fetched.
ENCLOSURE_TAG=$(grep -oE '<enclosure[^>]*>' "$TMP" | head -1 || true)
if [[ -z "$ENCLOSURE_TAG" ]]; then
  echo "❌ Appcast has no <enclosure> element — Sparkle has nothing to download."
  exit 1
fi
ENC_URL=$(printf '%s' "$ENCLOSURE_TAG" | sed -nE 's/.*[[:space:]]url="([^"]+)".*/\1/p')
ENC_LEN=$(printf '%s' "$ENCLOSURE_TAG" | sed -nE 's/.*[[:space:]]length="([0-9]+)".*/\1/p')
if [[ -z "$ENC_URL" ]]; then
  echo "❌ Could not parse enclosure url= from: $ENCLOSURE_TAG"
  exit 1
fi
echo "📦 Enclosure: $ENC_URL (declared length=${ENC_LEN:-unknown})"

ENC_CODE=$(curl -sS -L -I -o /dev/null -w "%{http_code}" "$ENC_URL" || echo "000")
if [[ "$ENC_CODE" != "200" ]]; then
  echo "❌ Enclosure DMG returned HTTP $ENC_CODE (expected 200)."
  echo "   This is the classic 'update failure' cause: the feed advertises a"
  echo "   version whose release asset isn't published. Cut the GitHub release"
  echo "   with the signed DMG attached, or revert the appcast to the last"
  echo "   published version."
  exit 1
fi

SERVED_LEN=$(curl -sS -L -I "$ENC_URL" 2>/dev/null \
  | awk 'tolower($1)=="content-length:"{v=$2} END{gsub(/[[:space:]\r]/,"",v); print v}')
if [[ -n "$ENC_LEN" && -n "$SERVED_LEN" && "$ENC_LEN" != "$SERVED_LEN" ]]; then
  echo "❌ Enclosure length mismatch: appcast declares $ENC_LEN, server serves $SERVED_LEN."
  echo "   Sparkle rejects a download whose size disagrees with the appcast."
  echo "   The DMG was likely re-uploaded after the appcast was signed —"
  echo "   regenerate the appcast from the published DMG (make appcast)."
  exit 1
fi
echo "✅ Enclosure DMG is reachable (HTTP 200) and length matches (${SERVED_LEN:-unverified}). Update is deliverable."
