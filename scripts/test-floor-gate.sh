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
# 2026-08-21: 3767 → 3771 (+4) — bounded THREAD Messages M1 explicit-service
#   preflight, service-correlated recovery, duplicate-Intent refusal, and exact
#   existing-Result adoption. Measured 3771 passed, 0 failed on
#   codex/thread-m1-reactivation-v2.
FLOOR="${BRIDGE_TEST_FLOOR:-3771}"

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
