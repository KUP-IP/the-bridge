#!/usr/bin/env bash
# test-floor-gate.sh — WS-C (v2.3, PKT-798)
#
# Locks the green test baseline as a CI gate. The custom harness
# (`swift build --show-bin-path -c debug`/TheBridgeTests) already exits non-zero on any failing
# test, but that does NOT catch tests being silently deleted or disabled —
# a suite that shrinks from 710 → 600 with 0 failures would otherwise pass
# CI unnoticed. This gate fails the build if the passing count drops below
# the floor OR any test fails.
#
# Full append-only FLOOR provenance: scripts/test-floor-gate-history.md
# 2026-08-06: 3556 → 3602 (+46) — Mail inbox management (mail_mailboxes /
#   mail_triage / mail_move / mail_archive / mail_mark / mail_trash + identity
#   harden + MailTriageSignals hermetic coverage). Measured green count after
#   .build/debug/TheBridgeTests on feat/mail-inbox-management.
# 2026-08-06: 3602 → 3605 (+3) — Red Team harden: silence→needsReview,
#   batch ARCHIVE confirm, mutate-vs-verify receipts + account required.
#   Measured green count after .build/debug/TheBridgeTests on
#   feat/mail-inbox-management.
# 2026-08-06: 3605 → 3613 (+8) — Red Team rework: drop noreply archiveHints,
#   batch archive/move force Request+neverAutoApprove, Archive↔All Mail
#   verify, succeeded=verified-only. Measured 3613 passed, 0 failed.
# 2026-08-14: 3613 → 3620 (+7) — PKT-FETCH-SKILL-SLUG-ALIAS: unique cached-slug
#   alias for fetch_skill (+2 hermetic). Remaining +5 already present on
#   9c73762 vs the 2026-08-06 floor stamp. Measured 3620 passed, 0 failed
#   after .build/debug/TheBridgeTests on feat/pkt-fetch-skill-slug-alias.
# 2026-08-14: 3620 → 3624 (+4) — issues #125/#130: messages_send `sent` is
#   dispatch success, not chat.db correlation; poll default 20×0.5s.
#   Measured 3624 passed, 0 failed on fix/issue-125-130-messages-correlation.
# 2026-08-15: 3624 → 3640 (+16) — issue #126: configurable messages_send
#   on-device approval (Always ask / session / trusted direct). Fail-closed
#   for group, THREAD, remote, jobs, and raw chatNNN. Measured 3640 passed,
#   0 failed on feat/issue-126-messages-approval-policy.
# 2026-08-15: 3640 → 3652 (+12) — issue #138: registry_create repair envelope
#   (state complete|partial|none, entityUrl, applied/failed), relation
#   preflight, updatePage applied vs canonicalized vs rejected. Measured
#   3652 passed, 0 failed on feat/issue-138-registry-repair-envelope.
# 2026-08-15: 3652 → 3666 (+14) — issue #129: command activation inserts at
#   the focused cursor (AX / synthetic Unicode), never reads or writes the
#   clipboard; fail-closed no-target / Accessibility-denied. Measured
#   3666 passed, 0 failed on feat/issue-129-command-cursor-insert.
# 2026-08-17: 3666 → 3744 (+78) — issue #160: registry_find compact ↔
#   hyphenated Notion UUID identity (+2 hermetic). Remaining +76 already
#   green on main 55236fa (including #163/#168). Measured 3744 passed,
#   0 failed on feat/issue-160-registry-uuid-normalize.
# 2026-08-17: 3744 → 3745 (+1) — unique geographic 2-token slices no longer
#   attach Memory projects; Next action: / transcript Next: strip to the
#   physical checkbox step. Measured 3745 passed, 0 failed on
#   feat/voice-memo-place-and-next-action.
# 2026-08-17: 3745 → 3747 (+2) — command insert Chromium pointer-focus
#   math. Measured 3747 passed, 0 failed on
#   feat/command-insert-cursor-webview.
# 2026-08-17: 3747 → 3751 (+4) — AX set success is not insert success:
#   read AXValue back; Chromium false success falls through to
#   click-then-type. Measured 3751 passed, 0 failed on
#   feat/command-insert-ax-readback.
# 2026-08-17: 3751 → 3754 (+3) — tall Chromium web area click inset
#   clears the 24px follow-up strip; skip AX set on AXWebArea.
#   Measured 3754 passed, 0 failed on
#   feat/command-insert-chromium-composer.
# 2026-08-17: 3754 → 3757 (+3) — unicode attach only on keyDown;
#   Chromium markdown composers duplicate keyUp chunks. Measured
#   3757 passed, 0 failed on feat/command-insert-unicode-keydown.
# 2026-08-18: 3757 → 3759 (+2) — unicode attach only on keyUp; carrier
#   0xFFFF so unset events are not kVK_ANSI_A; don't split markdown **.
#   Measured 3759 passed, 0 failed on
#   fix/command-insert-keyup-unicode.
# 2026-08-18: 3759 → 3761 (+2) — detached HEAD worktree_claim contract
#   (`branch: "(detached)"` + named-branch refusal). Measured 3761 passed,
#   0 failed on fix/v4.0.4-hardening.
# 2026-08-19: 3761 → 3763 (+2) — Electron insert keyDown/keyUp policy +
#   C1 single-line search name-only (empty body). Measured 3763 passed,
#   0 failed on feat/v405-local-insert-ui.
# 2026-08-21: 3763 → 3767 (+4) — Cursor caret-origin ghost, ChatGPT.app
#   Codex Chromium hint replace, Chrome keyDownAnsiA. Measured 3767
#   passed, 0 failed on feat/v405-local-insert-ui.
# 2026-08-21: 3767 → 3776 (+9) — canonical PACKETS identity, complete
#   34-column read-only schema preflight, live-schema metadata retention, and
#   config non-mutation proof. Measured 3776 passed, 0 failed on
#   codex/a1-integrity-preflight-v2.
# 2026-08-21: 3776 → 3780 (+4) — bounded THREAD Messages M1 explicit-service
#   preflight, service-correlated recovery, duplicate-Intent refusal, and exact
#   existing-Result adoption. Individually measured 3771 passed, 0 failed on
#   codex/thread-m1-reactivation-v2.
# 2026-08-21: 3780 → 3788 (+8) — governed node_test: owner-bound
#   trusted node:test imports, fixed permissions, bounded output/timeout,
#   and post-run identity revalidation. Individually measured 3775 passed, 0 failed
#   on codex/u2-governed-node-test-v2.
# 2026-08-22: 3788 → 3789 (+1) — physically canonicalize macOS's
#   /tmp → /private/tmp alias before constructing Node permission paths.
# 2026-08-23: 3789 → 3790 (+1) — coerce the text-bound Messages delivery
#   verification timestamp to SQLite numeric affinity before comparison.
# 2026-08-31: 3790 → 3844 (+54) — issue #198: inherit live inbound
#   iMessage/SMS or fail closed; RCS/mismatch refuse SMS fallback;
#   messages_chat/recent/search expose chat.db service. Measured 3844
#   passed, 0 failed on feat/issue-198-inherit-service. +5 hermetic on
#   this branch; remaining already green on main 707b8f4 vs stale 3790.
# 2026-09-02: 3844 → 3848 (+4) — load/save canonicalize PACKETS-shaped
#   packet+session duplicates to one `packet` key. Measured 3848 passed,
#   0 failed after rebase onto main (post-#200).
# 2026-09-02: 3848 → 3852 (+4) — awaiting_approval before MCP client
#   timeout (#184). Measured 3852 passed, 0 failed on
#   feat/issue-184-awaiting-approval after rebase onto main (post-#239).
# 2026-09-02: 3852 → 3854 (+2) — /mcp inbound count on /health (#189).
#   Measured 3854 passed, 0 failed on feat/issue-189-inbound-health
#   after rebase onto main (post-#201).
# 2026-09-02: 3854 → 3859 (+5) — registry rename-follow-id, id-keyed
#   writes, lastEditedTime revalidate, URL-or-UUID (#232–#235).
#   Measured 3859 passed, 0 failed on wave1-registry-234.
# 2026-09-02: 3859 → 3890 (+31) — Notion REST Wave 2 (#225–#231, #236–#237).
#   Measured 3890 passed, 0 failed on wave2-notion-rest.
# 2026-09-02: 3890 → 3896 (+6) — Messages Wave 3: tapback filter, exact
#   contact|chatIdentifier (no LIKE), is_read/date_read, filePath XOR body,
#   group-create catalog honesty (#216 #215 #217 #218 #204). Measured
#   3896 passed, 0 failed on wave3-messages.
# 2026-09-02: 3896 → 3899 (+3) — Calendar Wave 4: timeZoneIdentifier,
#   recurrence create + span thisEvent|futureEvents, EventKit alarms
#   (#206 #205 #207). Measured 3899 passed, 0 failed on wave4-calendar.
# 2026-09-02: 3899 → 3906 (+7) — Mail Wave 5: mail_read headers/attachments,
#   mail_reply/mail_forward + bcc, junk flag (#210 #208 #209). Measured
#   3906 passed, 0 failed on wave5-mail.
# 2026-09-02: 3906 → 3912 (+6) — GitHub Wave 6: open-tier issue/PR lists
#   (no body), parent + duplicateOf, gh_pr_review neverAutoApprove
#   (#219 #220 #221). Measured 3912 passed, 0 failed on wave6-github.
# 2026-09-02: 3912 → 3920 (+8) — Mac/UI Wave 7: limited contacts, notes
#   attachments, shortcut identifiers, SpeechAnalyzer opt-in off,
#   registrationChannel, displayIndex, Cmd+V web paste (#214 #211 #213
#   #212 #223 #224 #238). Measured 3920 passed, 0 failed on wave7-mac-ui.
# 2026-09-03: 3920 → 3927 (+7) — hotfix #238 Safari/WebKit Cmd+V paste,
#   leftover ⌃⌥⇧ HID key-up, Command-held UCKeyTranslate, pasteboard
#   restore-on-throw; gh_pr_review comment event dropped; keyboard_type
#   copy drops Input Monitoring claim; Contacts .limited unit coverage
#   (in PermissionsModuleTests — runPermissionManagerTests is skipped).
#   LaunchAgent AssociatedBundleIdentifiers asserted in existing plist
#   test (no extra count). CI measured 3926 passed / 0 failed on 1f18ed4
#   before the Contacts test was moved to a live runner; floor 3927 after
#   that move.
# 2026-09-04: 3927 → 3935 (+8) — #249 RCS/unknown SMS operator override:
#   allowSmsDespiteLiveService on messages_send. Inherit-or-refuse held for
#   omit and iMessage↔SMS mismatch; RCS stays out of the send enum.
#   +8 net-new MessagesModuleTests (RCS/unknown refuse + authorized SMS +
#   mismatch + resolveSendService matrix). CI measured 3935 passed, 0 failed
#   on cursor/rcs-sms-operator-override-394d (run 33825894053).
# 2026-09-04: 3935 → 3942 (+7) — #251 Cmd+V pasteboard consume window:
#   Handy-floor 60/60 delays (post 120ms because Bridge restores), changeCount
#   publish poll, restore-after-perform recording sleep double, fake delayed
#   consumer, empty-prior restore, restore-on-throw still waits postDelay.
#   +7 net-new CommandCursorInsertTests. CI measured 3942 passed, 0 failed
#   on cursor/fix-251-cmdv-prior-clipboard-f9ab (run 33897067337).
# 2026-09-04: 3942 → 3947 (+5) — Runtime Exposure: optional Deprecation Date
#   (warn, not schema_missing) + governed orphan purge API. +4 hermetic
#   SkillExposureAuthorityTests (missing-column compile, optional warning,
#   explicit named purge, generic sweep HOLD for outreach-dispatch) +1
#   SkillsModuleTests (purge orphans requires routeReceipt). Floor is
#   3942 + net-new after rebase onto #252. Pre-rebase isolated CI
#   measured 3940 (run 33895348693); CI must re-measure 3947.
# 2026-09-04: 3947 → 3967 (+20) — #256 Time Keepr–style b-W.D-NN screen
#   filenames. +20 hermetic ScreenArtifactNamingTests (ISO week/day with
#   injected America/Chicago, shared png+mp4 sequence, new-day reset,
#   leftover epoch names ignored, cleanup keeps today / deletes prior day).
#   Floor is main 3947 + net-new tests after rebase onto #253.
# 2026-09-04: 3967 → 3973 (+6) — #258 notify-default + Always Allow
#   everywhere. Drop neverAutoApprove execution floor; Confirm cards always
#   offer Always Allow; standing_orders_delete registered Request; default
#   ToolRegistration tier is Notify. +6 SecurityGateUXTests. CI must
#   re-measure.
# 2026-09-04: 3973 → 3983 (+10) — #258 live-verify Confirm delivery
#   fallback. Menu-bar Confirm + ATTENTION for in-flight Request (remote
#   and local); DefaultContentHidden=false; request userInfo. +10
#   SecurityGateUXTests. CI must re-measure.
# 2026-09-04: 3983 → 3989 (+6) — #260 live-fail Confirm body. Status-item
#   click / pending Request presents Deny/Allow/Always Allow; badge not
#   cleared until resolved; banner default/dismiss present-body not Deny;
#   Always Allow still sticky Notify. +6 SecurityGateUXTests. CI must
#   re-measure.
# 2026-09-06: 3989 → 4013 (+24) — calendar free/busy v0 spike (Isaiah GO).
#   Read-only calendar_free_busy; occupancy SSOT = FOCUS EventKit only
#   (Meetings / Google Meetings freeBusy out of scope). +23
#   CalendarModuleTests + 1 access-denied nested. CI must re-measure.
# 2026-09-06: 4013 → 4017 (+4) — #263 Request-tier awaiting_approval.
#   First Request call returns pending immediately (no 25s UN wait /
#   NSAlert auto-allow). +4 SecurityGateUXTests. CI run 34060644427
#   measured 4017 passed, 0 failed on 4d91254.
# 2026-09-07: 4017 → 4027 (+10) — #264 notify stickies only on explicit
#   Always Allow, rebased onto #263. Compact banner Allow-first; Confirm
#   no default button; persistNotifySticky source log. +10
#   SecurityGateUXTests. Isolated #264 measure was 4013 → 4023 on CI run
#   34061106853 (SHA 35d2737); stacked floor is additive 4017 + 10.
# 2026-09-07: 4027 → 4034 (+7) — #262 assertive Confirm + Time Sensitive.
#   Auto-present on escalate, Always Allow visual primary (not keyboard
#   default), Time Sensitive registration, regular policy while Confirm
#   visible, dual-notify / Focus docs. +7 ConfirmPresentationUXTests
#   stacked on #267's 4027. CI must re-measure (Linux host cannot
#   compile macOS 26).
# 2026-09-07: 4034 → 4038 (+4) — #262 LIVE FAIL rewrite hermetic extras
#   (auto-front from pending surface, not host flag). CI run 34138318943
#   on be574b51 measured 4038 total / 4037 passed / 1 failed: surface
#   observer Task hop raced `second escalate re-asserts presented`.
#   Observer now MainActor.assumeIsolated; test asserts on one hop.
#   Floor is the measured green count after that race fix.
# 2026-09-08: 4038 → 4047 (+9) — #262/#264 LIVE fail on 2bd375aa / PR #269.
#   LSUIElement force-front plan (policy before create) + sticky gate
#   refuses unique-foreground / pending-escalate / default-button persist.
#   +9 ConfirmLiveFailContractTests. CI must re-measure (Linux host cannot
#   compile macOS 26).
FLOOR="${BRIDGE_TEST_FLOOR:-4047}"

echo "🧪 test-floor-gate: building debug test executable + running suite (floor=${FLOOR})..."
swift build -c debug --product TheBridgeTests
BIN="$(swift build --show-bin-path -c debug)/TheBridgeTests"
if [ ! -x "$BIN" ]; then
  echo "::error::test-floor-gate: compiled test binary is missing or not executable at $BIN"
  exit 127
fi

LOG="$(mktemp -t bridge-test-floor.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

# A failing run is evidence, not disposable noise. Copy the complete log to a
# stable operator-visible directory before the temporary file is cleaned up,
# then print both the path and every explicit failure row found anywhere in the
# log (not merely the tail). Tests/CI may override this location.
FAILURE_DIR="${BRIDGE_TEST_FAILURE_DIR:-${HOME}/Library/Logs/TheBridge/test-floor-failures}"
retain_failure_log() {
  mkdir -p "$FAILURE_DIR"
  RETAINED_LOG="${FAILURE_DIR}/test-floor-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
  cp "$LOG" "$RETAINED_LOG"
  echo "::notice::test-floor-gate: complete failure log retained at $RETAINED_LOG"
  echo "--- failure rows from complete test output ---"
  grep -aE '(^|[[:space:]])❌|::error::|error:' "$RETAINED_LOG" || echo "(no explicit failure row found; inspect the retained complete log)"
  echo "--- end failure rows ---"
}

# Watchdog: cap the test binary at DEADLINE seconds (default 1500 = 25 min;
# local run is ~5 min, CI macos-26 is ~3x slower). Override with
# TEST_WATCHDOG_SECONDS — a short value (e.g. 5) makes the watchdog testable.
#
# This is a REAL EXTERNAL watchdog, not `perl -e 'alarm N; exec'`. On macOS the
# SIGALRM timer set by alarm() is CLEARED by exec() (the new image starts with no
# pending alarm), so the old pattern never actually killed a hung binary — it ran
# until the CI step/job timeout. Instead we now: launch the binary in the
# background, capture its PID, start a separate killer subshell that SIGKILLs that
# PID after DEADLINE, and `wait` on the binary. On normal completion we KILL THE
# KILLER so a finished run leaves no stray `sleep` and the script never blocks on
# it. On a watchdog kill we FAIL FAST with the last logged test line so the hang
# is diagnosable instead of an opaque multi-hour cancel.
DEADLINE="${TEST_WATCHDOG_SECONDS:-1500}"
#
# Bounded retry on the harness teardown flake: the runner emits its summary from
# a tail that, on a fully-completed suite, can intermittently lose a race with
# process teardown and drop the final `Results:` line — the binary still exits 0
# and every test ran (the per-test ✅ lines are all present). That is NOT a test
# failure, so re-run up to ATTEMPTS times until the summary is captured. A real
# hang (watchdog) or a genuine non-zero exit fails immediately with no retry, and
# the floor/failure checks below are unchanged.
ATTEMPTS=3
LINE=""
for attempt in $(seq 1 "$ATTEMPTS"); do
  set +e
  # Run the binary in the background, tee'ing its combined output to the log so
  # the timeout path can print the last test line. `$!` is the binary's PID.
  "$BIN" > >(tee "$LOG") 2>&1 &
  BIN_PID=$!

  # External killer: SIGKILL the binary if it outlives DEADLINE. Captured PID so
  # we can cancel it on a clean finish.
  ( sleep "$DEADLINE"; kill -9 "$BIN_PID" 2>/dev/null ) &
  KILLER_PID=$!

  # Block until the binary exits (normally, or via the killer's SIGKILL).
  wait "$BIN_PID"
  RC=$?

  # Cleanup: cancel + reap the killer so a completed run leaves no stray sleep
  # and the script doesn't block waiting on it. Kill the killer's `sleep` CHILD
  # first (while the subshell is still alive so `pkill -P` can resolve it),
  # otherwise killing only the subshell orphans the `sleep` and it keeps running
  # for the full DEADLINE. Then kill + reap the subshell itself.
  pkill -P "$KILLER_PID" 2>/dev/null
  kill "$KILLER_PID" 2>/dev/null
  wait "$KILLER_PID" 2>/dev/null
  set -e

  # SIGKILL from the watchdog surfaces as 137 (128+9). (128+SIGALRM=142 / 14 are
  # kept as a defensive fallback in case a future change reintroduces an alarm.)
  if [ "$RC" -eq 137 ] || [ "$RC" -eq 142 ] || [ "$RC" -eq 14 ]; then
    echo "::error::test-floor-gate: test binary exceeded ${DEADLINE}s watchdog and was killed"
    retain_failure_log
    echo "--- last 60 lines of test output (so you can see which test hung) ---"
    tail -60 "$LOG" || true
    echo "--- end of test output tail ---"
    exit 124
  fi
  if [ "$RC" -ne 0 ]; then
    echo "::error::test-floor-gate: test binary exited with code $RC (non-zero, non-timeout)"
    retain_failure_log
    echo "--- last 60 lines of test output ---"
    tail -60 "$LOG" || true
    echo "--- end of test output tail ---"
    exit "$RC"
  fi

  LINE="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed, [0-9]+ total' "$LOG" | tail -1 || true)"
  if [ -n "$LINE" ]; then
    break
  fi
  echo "::warning::test-floor-gate: attempt ${attempt}/${ATTEMPTS} exited 0 but emitted no 'Results:' line (known harness teardown flake) — retrying"
done

LINE="$(tr -d '\000-\010\013\014\016-\037' < "$LOG" | grep -aE 'Results: [0-9]+ passed, [0-9]+ failed, [0-9]+ total' | tail -1 || true)"
if [ -z "$LINE" ]; then
  echo "::error::test-floor-gate: no 'Results:' summary line after ${ATTEMPTS} attempts"
  retain_failure_log
  exit 2
fi

PASSED="$(printf '%s\n' "$LINE" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')"
FAILED="$(printf '%s\n' "$LINE" | sed -E 's/^Results: [0-9]+ passed, ([0-9]+) failed.*/\1/')"

if [ "$FAILED" -ne 0 ]; then
  echo "::error::test-floor-gate: ${FAILED} failing test(s) — green bar broken"
  retain_failure_log
  exit 1
fi

if [ "$PASSED" -lt "$FLOOR" ]; then
  echo "::error::test-floor-gate: passed=${PASSED} is BELOW floor=${FLOOR} — tests were removed or disabled. If this drop is intentional, lower the floor in scripts/test-floor-gate.sh in the same change and record why."
  retain_failure_log
  exit 1
fi

echo "✅ test-floor-gate OK: passed=${PASSED} >= floor=${FLOOR}, failed=0"
