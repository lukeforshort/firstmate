#!/usr/bin/env bash
# Behavior tests for the supervision-symptom recurrence tracker.
#
# The management audit (data/mgmt-audit-2026-07-10, finding B2/L4) found the same
# supervision failure - arm reporting FAILED though a watcher was alive - re-learned
# as a fresh quirk and hand-fixed with `--restart` over and over, with no signal
# that it was the SAME symptom recurring and deserved a structural fix. This suite
# pins the tracker that closes that gap:
#   ENGINE  - bin/fm-symptom-lib.sh: durable per-class counting, the threshold at
#             which one announcement line surfaces, distinct-class isolation,
#             ordinals, first-seen date, debounce, and unknown-class rejection.
#   SITES   - the three existing detection sites (fm-turnend-guard.sh guard-blind-
#             turn, fm-guard.sh watcher-down/worktree-tangle, fm-watch-arm.sh
#             arm-failed/forced-restart) surface the advisory at threshold, stay
#             silent below it, and add no noise on the healthy path.
# All hermetic over temp dirs; no real agent session or long-lived watcher runs.
set -u

# TZ is pinned so the human-readable first-seen date derived from an epoch is
# deterministic regardless of the host timezone.
export TZ=UTC

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-symptom-lib.sh
. "$ROOT/bin/fm-symptom-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-symptom-lib)
fm_git_identity fmtest fmtest@example.invalid

RECUR_MARK='RECURRING SUPERVISION SYMPTOM'
FILE_TASK_MARK='file a structural fix ship task'

# fresh_state <name>: a clean per-test state dir, echoed. Each test gets its own so
# durable logs never bleed across cases.
fresh_state() {
  local s="$TMP_ROOT/$1-state"
  rm -rf "$s"
  mkdir -p "$s"
  printf '%s\n' "$s"
}

# --- ENGINE: bin/fm-symptom-lib.sh ------------------------------------------

# Below threshold every occurrence is silent and returns 0, but the durable log
# still grows one line per incident so a later session sees the running count.
test_below_threshold_silent_but_durable() {
  local state out rc
  state=$(fresh_state below-threshold)
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=3 FM_SYMPTOM_NOW=1000 \
    out=$(fm_symptom_record arm-failed "first"); rc=$?
  expect_code 0 "$rc" "first sub-threshold record must return 0"
  [ -z "$out" ] || fail "first sub-threshold record must be silent, got: $out"
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=3 FM_SYMPTOM_NOW=2000 \
    out=$(fm_symptom_record arm-failed "second"); rc=$?
  expect_code 0 "$rc" "second sub-threshold record must return 0"
  [ -z "$out" ] || fail "second sub-threshold record must be silent, got: $out"
  [ "$(wc -l < "$state/.symptom-arm-failed.log")" -eq 2 ] \
    || fail "durable log must hold one line per sub-threshold incident"
  pass "fm_symptom_record: sub-threshold occurrences are silent but durably logged"
}

# At the threshold the announcement surfaces: it names the class, the ordinal
# count, the first-seen date, the log path, and the file-a-structural-fix
# instruction - and it keeps surfacing on every occurrence past the threshold.
test_threshold_announces_with_context() {
  local state out
  state=$(fresh_state threshold)
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=3 FM_SYMPTOM_NOW=1751328000 \
    fm_symptom_record arm-failed "one" >/dev/null
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=3 FM_SYMPTOM_NOW=1751414400 \
    fm_symptom_record arm-failed "two" >/dev/null
  out=$(FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=3 FM_SYMPTOM_NOW=1751500800 \
    fm_symptom_record arm-failed "three")
  assert_contains "$out" "$RECUR_MARK" "threshold announcement must lead with the recurring-symptom marker"
  assert_contains "$out" "arm-failed" "announcement must name the symptom class"
  assert_contains "$out" "3rd occurrence" "announcement must carry the ordinal count"
  assert_contains "$out" "since 2025-07-01" "announcement must carry the first-seen date"
  assert_contains "$out" "$state/.symptom-arm-failed.log" "announcement must link the prior-incident log path"
  assert_contains "$out" "$FILE_TASK_MARK" "announcement must tell the agent to file a structural fix"
  # The since-date is the FIRST incident's date, not the current one.
  assert_not_contains "$out" "since 2025-07-03" "since-date must be first-seen, not the latest occurrence"
  # Fourth occurrence keeps announcing and advances the ordinal.
  out=$(FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=3 FM_SYMPTOM_NOW=1751587200 \
    fm_symptom_record arm-failed "four")
  assert_contains "$out" "4th occurrence" "past-threshold occurrences must keep announcing with an advancing ordinal"
  pass "fm_symptom_record: threshold announcement carries count, first-seen date, log path, and the file-a-fix instruction"
}

# Distinct classes count in separate logs and never cross-contaminate.
test_distinct_classes_isolated() {
  local state out
  state=$(fresh_state distinct)
  # Drive arm-failed to threshold while forced-restart stays at one.
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=2 FM_SYMPTOM_NOW=100 \
    fm_symptom_record arm-failed a >/dev/null
  out=$(FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=2 FM_SYMPTOM_NOW=200 \
    fm_symptom_record forced-restart r)
  [ -z "$out" ] || fail "forced-restart (count 1) must stay silent while arm-failed climbs: $out"
  out=$(FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=2 FM_SYMPTOM_NOW=300 \
    fm_symptom_record arm-failed b)
  assert_contains "$out" "arm-failed" "arm-failed must reach its own threshold independently"
  assert_contains "$out" "2nd occurrence" "arm-failed count must not include forced-restart incidents"
  [ "$(wc -l < "$state/.symptom-forced-restart.log")" -eq 1 ] \
    || fail "forced-restart log must hold only its own single incident"
  pass "fm_symptom_record: distinct classes count in separate logs without cross-contamination"
}

# An unknown class is refused (rc 2, stderr note) and writes no log, so a typo can
# never mint a phantom class or silently swallow a real incident.
test_unknown_class_refused() {
  local state err rc
  state=$(fresh_state unknown)
  err=$(FM_STATE_OVERRIDE="$state" fm_symptom_record not-a-real-class detail 2>&1 >/dev/null); rc=$?
  expect_code 2 "$rc" "unknown class must return 2"
  assert_contains "$err" "unknown symptom class" "unknown class must explain itself on stderr"
  assert_absent "$state/.symptom-not-a-real-class.log" "unknown class must not write a log"
  pass "fm_symptom_record: unknown class is refused with rc 2 and writes no log"
}

# A positive debounce collapses a same-episode storm into one incident: a repeat
# within the window records nothing and returns 1; the next repeat outside the
# window counts again.
test_debounce_collapses_storm() {
  local state rc
  state=$(fresh_state debounce)
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_NOW=5000 fm_symptom_record watcher-down a 100 >/dev/null; rc=$?
  expect_code 0 "$rc" "first debounced-site record must count (rc 0)"
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_NOW=5050 fm_symptom_record watcher-down b 100 >/dev/null; rc=$?
  expect_code 1 "$rc" "a repeat within the debounce window must be collapsed (rc 1)"
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_NOW=5200 fm_symptom_record watcher-down c 100 >/dev/null; rc=$?
  expect_code 0 "$rc" "a repeat past the debounce window must count again (rc 0)"
  [ "$(wc -l < "$state/.symptom-watcher-down.log")" -eq 2 ] \
    || fail "debounce must leave exactly two incidents (the collapsed repeat excluded)"
  pass "fm_symptom_record: positive debounce collapses same-episode repeats, counts distinct episodes"
}

# A discrete once-per-event site passes no debounce, so every occurrence counts
# even back-to-back at the same instant.
test_no_debounce_counts_every_event() {
  local state
  state=$(fresh_state no-debounce)
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_NOW=7000 fm_symptom_record forced-restart a >/dev/null
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_NOW=7000 fm_symptom_record forced-restart b >/dev/null
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_NOW=7000 fm_symptom_record forced-restart c >/dev/null
  [ "$(wc -l < "$state/.symptom-forced-restart.log")" -eq 3 ] \
    || fail "a no-debounce site must count every occurrence, even at the same instant"
  pass "fm_symptom_record: a no-debounce site counts every discrete event"
}

# The threshold is overridable and a malformed value falls back to the default.
test_threshold_override_and_fallback() {
  local state out
  state=$(fresh_state thr-override)
  out=$(FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=1 FM_SYMPTOM_NOW=10 \
    fm_symptom_record guard-blind-turn once)
  assert_contains "$out" "1st occurrence" "threshold=1 must announce on the very first occurrence"
  # A garbage threshold must not disable announcing: it falls back to the default (3).
  state=$(fresh_state thr-garbage)
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=bogus FM_SYMPTOM_NOW=10 fm_symptom_record guard-blind-turn a >/dev/null
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=bogus FM_SYMPTOM_NOW=20 fm_symptom_record guard-blind-turn b >/dev/null
  out=$(FM_STATE_OVERRIDE="$state" FM_SYMPTOM_THRESHOLD=bogus FM_SYMPTOM_NOW=30 fm_symptom_record guard-blind-turn c)
  assert_contains "$out" "3rd occurrence" "a malformed threshold must fall back to the default of 3, not disable announcing"
  pass "fm_symptom_record: threshold is overridable and a malformed value falls back to the default"
}

# The ordinal helper is correct across the tricky 11-13 / 21-23 boundaries.
test_ordinal_formatting() {
  local got want
  got=""
  for n in 1 2 3 4 11 12 13 21 22 23 101 111; do
    got="$got $(fm_symptom_ordinal "$n")"
  done
  want=" 1st 2nd 3rd 4th 11th 12th 13th 21st 22nd 23rd 101st 111th"
  [ "$got" = "$want" ] || fail "ordinal mismatch: got '$got' want '$want'"
  pass "fm_symptom_ordinal: correct across the 11-13 and 21-23 suffix boundaries"
}

# Detail text is flattened so a tab or newline in a caller's detail can never
# corrupt the one-line-per-incident TSV log.
test_detail_sanitized() {
  local state lines
  state=$(fresh_state sanitize)
  FM_STATE_OVERRIDE="$state" FM_SYMPTOM_NOW=1 \
    fm_symptom_record arm-failed "line one
line two	tabbed" >/dev/null
  lines=$(wc -l < "$state/.symptom-arm-failed.log")
  [ "$lines" -eq 1 ] || fail "a multiline/tabbed detail must stay one log line, got $lines"
  pass "fm_symptom_record: detail newlines and tabs are flattened to keep one incident per line"
}

# The class predicate accepts the coarse fixed vocabulary and rejects anything else.
test_class_known_predicate() {
  local c
  for c in arm-failed forced-restart guard-blind-turn watcher-down worktree-tangle stale-escalation; do
    fm_symptom_class_known "$c" || fail "class '$c' must be recognized"
  done
  fm_symptom_class_known bogus && fail "an unknown class must not be recognized"
  pass "fm_symptom_class_known: accepts the coarse fixed vocabulary, rejects the rest"
}

# --- SITE: bin/fm-guard.sh (watcher-down, worktree-tangle) -------------------
#
# Driven through the REAL guard (its scripts resolve from $ROOT/bin), scoped to a
# temp state dir. FM_ROOT_OVERRIDE points the tangle check at a non-git dir so it
# stays inert for the watcher-down cases.

run_guard() {  # <state-dir> <root-override> [extra env assignments...]
  local state=$1 root=$2
  shift 2
  env "$@" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

# Pre-seed a symptom log with <n> incidents so the next real record crosses the
# threshold deterministically.
seed_symptom_log() {  # <state-dir> <class> <n>
  local state=$1 class=$2 n=$3 i
  for ((i = 1; i <= n; i++)); do
    printf '%s\t%s\t%s\n' "$((100 + i))" '2025-07-01T00:00:00' "seed$i" >> "$state/.symptom-$class.log"
  done
}

test_guard_watcher_down_announces_at_threshold() {
  local state nongit out
  state=$(fresh_state guard-thresh)
  nongit="$TMP_ROOT/guard-thresh-nongit"
  mkdir -p "$nongit"
  : > "$state/task.meta"
  seed_symptom_log "$state" watcher-down 2
  # Debounce disabled so the seeded run deterministically crosses the threshold.
  out=$(run_guard "$state" "$nongit" FM_SYMPTOM_GUARD_DEBOUNCE=0)
  assert_contains "$out" "WATCHER DOWN" "the watcher-down banner must still fire"
  assert_contains "$out" "$RECUR_MARK" "at threshold the banner must carry the recurrence advisory"
  assert_contains "$out" "watcher-down" "the advisory must name the watcher-down class"
  assert_contains "$out" "$FILE_TASK_MARK" "the advisory must tell the agent to file a structural fix"
  pass "fm-guard: watcher-down banner carries the recurrence advisory at threshold"
}

test_guard_watcher_down_silent_below_threshold() {
  local state nongit out
  state=$(fresh_state guard-below)
  nongit="$TMP_ROOT/guard-below-nongit"
  mkdir -p "$nongit"
  : > "$state/task.meta"
  out=$(run_guard "$state" "$nongit" FM_SYMPTOM_GUARD_DEBOUNCE=0)
  assert_contains "$out" "WATCHER DOWN" "the watcher-down banner must fire on the first lapse"
  assert_not_contains "$out" "$RECUR_MARK" "a first-time lapse must not carry a recurrence advisory"
  [ "$(wc -l < "$state/.symptom-watcher-down.log")" -eq 1 ] \
    || fail "the first lapse must record exactly one incident"
  pass "fm-guard: a first-time watcher-down lapse records one incident and stays quiet"
}

test_guard_healthy_records_nothing() {
  local state nongit out
  state=$(fresh_state guard-healthy)
  nongit="$TMP_ROOT/guard-healthy-nongit"
  mkdir -p "$nongit"
  : > "$state/task.meta"
  touch "$state/.last-watcher-beat"
  out=$(run_guard "$state" "$nongit" FM_SYMPTOM_GUARD_DEBOUNCE=0)
  assert_not_contains "$out" "WATCHER DOWN" "a fresh beacon must keep the guard silent"
  assert_absent "$state/.symptom-watcher-down.log" "the healthy path must record no symptom (no noise)"
  pass "fm-guard: a fresh beacon adds no symptom noise"
}

test_guard_episode_collapses_rapid_repeats() {
  local state nongit
  state=$(fresh_state guard-episode)
  nongit="$TMP_ROOT/guard-episode-nongit"
  mkdir -p "$nongit"
  : > "$state/task.meta"
  # Two back-to-back guard fires in the same staleness episode (the beacon is
  # absent both times, so the episode key is identical). watcher-down records only
  # when this session owns the full banner, which the episode claim grants exactly
  # once per episode - so the second fire records nothing and one incident remains.
  run_guard "$state" "$nongit" >/dev/null
  run_guard "$state" "$nongit" >/dev/null
  [ "$(wc -l < "$state/.symptom-watcher-down.log")" -eq 1 ] \
    || fail "same-episode watcher-down fires must collapse to one incident via the episode claim"
  pass "fm-guard: same-episode watcher-down repeats collapse to a single incident"
}

test_guard_distinct_episodes_each_record() {
  local state nongit beat
  state=$(fresh_state guard-episodes)
  nongit="$TMP_ROOT/guard-episodes-nongit"
  mkdir -p "$nongit"
  : > "$state/task.meta"
  beat="$state/.last-watcher-beat"
  # Episode 1: beacon absent (key "beat:absent"). Records incident 1.
  run_guard "$state" "$nongit" >/dev/null
  # Episode 2: a stale beacon now exists, so the episode key changes to its mtime
  # and the guard treats this as a fresh staleness episode - even though the
  # watcher is still down - and records a second incident. This is exactly the
  # recovered-then-restale case the episode key distinguishes.
  touch -d '@100' "$beat" 2>/dev/null || touch -t 200001010000 "$beat"
  run_guard "$state" "$nongit" >/dev/null
  [ "$(wc -l < "$state/.symptom-watcher-down.log")" -eq 2 ] \
    || fail "two distinct staleness episodes must record two separate incidents"
  pass "fm-guard: distinct watcher-down episodes each record an incident"
}

test_guard_read_only_records_nothing() {
  local state nongit out
  state=$(fresh_state guard-ro)
  nongit="$TMP_ROOT/guard-ro-nongit"
  mkdir -p "$nongit"
  : > "$state/task.meta"
  seed_symptom_log "$state" watcher-down 2
  out=$(run_guard "$state" "$nongit" FM_SYMPTOM_GUARD_DEBOUNCE=0 FM_GUARD_READ_ONLY=1)
  assert_contains "$out" "WATCHER DOWN" "a read-only session must still surface the lapse banner"
  assert_not_contains "$out" "$RECUR_MARK" "a read-only session must not record or announce (it holds no lock)"
  [ "$(wc -l < "$state/.symptom-watcher-down.log")" -eq 2 ] \
    || fail "a read-only session must not append to the incident log"
  pass "fm-guard: a read-only advisory pass records nothing and never crosses the threshold"
}

test_guard_worktree_tangle_announces_at_threshold() {
  local repo state out
  repo="$TMP_ROOT/tangle-repo"
  git init -q -b main "$repo"
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" checkout -q -B fm/tangle-branch
  state=$(fresh_state tangle)
  seed_symptom_log "$state" worktree-tangle 2
  out=$(run_guard "$state" "$repo" FM_SYMPTOM_GUARD_DEBOUNCE=0)
  assert_contains "$out" "WORKTREE TANGLE" "the tangle banner must fire on a stranded primary"
  assert_contains "$out" "$RECUR_MARK" "a recurring tangle must carry the recurrence advisory"
  assert_contains "$out" "worktree-tangle" "the advisory must name the worktree-tangle class"
  pass "fm-guard: worktree-tangle banner carries the recurrence advisory at threshold"
}

# --- SITE: bin/fm-turnend-guard.sh (guard-blind-turn) -----------------------
#
# The turn-end guard fires only in a PRIMARY-shaped checkout, so each case gets a
# plain (non-worktree) git repo carrying copies of the guard scripts under bin/.

install_turnend_scripts() {  # <dir>
  local dir=$1 s
  mkdir -p "$dir/bin" "$dir/state"
  for s in fm-turnend-guard.sh fm-supervision-instructions.sh fm-harness.sh \
           fm-supervision-lib.sh fm-wake-lib.sh fm-symptom-lib.sh; do
    cp "$ROOT/bin/$s" "$dir/bin/$s"
  done
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

run_turnend_hook() {  # <dir>
  local dir=$1 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

test_turnend_announces_at_threshold() {
  local dir out status
  dir="$TMP_ROOT/turnend-thresh"
  install_turnend_scripts "$dir"
  : > "$dir/state/task1.meta"
  seed_symptom_log "$dir/state" guard-blind-turn 2
  out=$(run_turnend_hook "$dir"); status=$?
  expect_code 2 "$status" "the blind-turn guard must still block"
  assert_contains "$out" "TURN WOULD END BLIND" "the blind-turn banner must fire"
  assert_contains "$out" "$RECUR_MARK" "at threshold the blind-turn banner must carry the recurrence advisory"
  assert_contains "$out" "guard-blind-turn" "the advisory must name the guard-blind-turn class"
  pass "fm-turnend-guard: blind-turn banner carries the recurrence advisory at threshold"
}

test_turnend_silent_below_threshold() {
  local dir out status
  dir="$TMP_ROOT/turnend-below"
  install_turnend_scripts "$dir"
  : > "$dir/state/task1.meta"
  out=$(run_turnend_hook "$dir"); status=$?
  expect_code 2 "$status" "the blind-turn guard must block on a first lapse too"
  assert_contains "$out" "TURN WOULD END BLIND" "the blind-turn banner must fire"
  assert_not_contains "$out" "$RECUR_MARK" "a first blind turn must not carry a recurrence advisory"
  [ "$(wc -l < "$dir/state/.symptom-guard-blind-turn.log")" -eq 1 ] \
    || fail "a first blind turn must record exactly one incident"
  pass "fm-turnend-guard: a first blind turn records one incident and stays quiet"
}

test_turnend_no_inflight_records_nothing() {
  local dir out status
  dir="$TMP_ROOT/turnend-idle"
  install_turnend_scripts "$dir"
  out=$(run_turnend_hook "$dir"); status=$?
  expect_code 0 "$status" "the guard must be a silent no-op with nothing in flight"
  [ -z "$out" ] || fail "the guard must produce no output with nothing in flight: $out"
  assert_absent "$dir/state/.symptom-guard-blind-turn.log" "the no-work path must record no symptom (no noise)"
  pass "fm-turnend-guard: nothing in flight records no symptom"
}

# --- SITE: bin/fm-watch-arm.sh (arm-failed, forced-restart) -----------------
#
# The arm forks a real watcher child; a stub watcher that never becomes healthy
# plus a short confirm timeout makes the FAILED path resolve fast and hermetically.

install_arm_scripts() {  # <dir>
  local dir=$1 s
  mkdir -p "$dir/bin" "$dir/state"
  for s in fm-watch-arm.sh fm-wake-lib.sh fm-symptom-lib.sh; do
    cp "$ROOT/bin/$s" "$dir/bin/$s"
  done
  chmod +x "$dir/bin/fm-watch-arm.sh"
  # A stub watcher that exits immediately without ever taking the lock, so the arm
  # can only reach its FAILED path.
  cat > "$dir/bin/fm-watch.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$dir/bin/fm-watch.sh"
}

run_arm() {  # <dir> [--restart]
  local dir=$1 home
  shift
  home=$(cd "$dir" && pwd)
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ARM_CONFIRM_TIMEOUT=1 FM_GUARD_GRACE=1 \
    bash "$dir/bin/fm-watch-arm.sh" "$@" 2>&1
}

test_arm_failed_announces_at_threshold() {
  local dir out status
  dir="$TMP_ROOT/arm-failed-thresh"
  install_arm_scripts "$dir"
  seed_symptom_log "$dir/state" arm-failed 2
  out=$(run_arm "$dir"); status=$?
  expect_code 1 "$status" "the arm must report FAILED when no watcher becomes healthy"
  assert_contains "$out" "FAILED" "the FAILED status line must still print"
  assert_contains "$out" "$RECUR_MARK" "at threshold the FAILED path must carry the recurrence advisory"
  assert_contains "$out" "arm-failed" "the advisory must name the arm-failed class"
  pass "fm-watch-arm: FAILED path carries the recurrence advisory at threshold"
}

test_arm_failed_silent_below_threshold() {
  local dir out status
  dir="$TMP_ROOT/arm-failed-below"
  install_arm_scripts "$dir"
  out=$(run_arm "$dir"); status=$?
  expect_code 1 "$status" "the arm must report FAILED"
  assert_contains "$out" "FAILED" "the FAILED status line must print"
  assert_not_contains "$out" "$RECUR_MARK" "a first FAILED must not carry a recurrence advisory"
  [ "$(wc -l < "$dir/state/.symptom-arm-failed.log")" -eq 1 ] \
    || fail "a first FAILED must record exactly one incident"
  pass "fm-watch-arm: a first FAILED records one incident and stays quiet"
}

test_arm_forced_restart_announces_at_threshold() {
  local dir out
  dir="$TMP_ROOT/arm-restart-thresh"
  install_arm_scripts "$dir"
  seed_symptom_log "$dir/state" forced-restart 2
  # --restart records the forced-restart incident up front, before any watcher
  # work, then falls through to a FAILED arm (harmless here). We assert the
  # forced-restart advisory, which surfaces regardless of the arm outcome.
  out=$(run_arm "$dir" --restart)
  assert_contains "$out" "$RECUR_MARK" "at threshold a forced restart must carry the recurrence advisory"
  assert_contains "$out" "forced-restart" "the advisory must name the forced-restart class"
  assert_contains "$out" "$FILE_TASK_MARK" "the advisory must tell the agent to file a structural fix"
  pass "fm-watch-arm: a forced restart carries the recurrence advisory at threshold"
}

test_arm_forced_restart_silent_below_threshold() {
  local dir out
  dir="$TMP_ROOT/arm-restart-below"
  install_arm_scripts "$dir"
  out=$(run_arm "$dir" --restart)
  assert_not_contains "$out" "$RECUR_MARK" "a first forced restart must not carry a recurrence advisory"
  [ "$(wc -l < "$dir/state/.symptom-forced-restart.log")" -eq 1 ] \
    || fail "a first forced restart must record exactly one incident"
  pass "fm-watch-arm: a first forced restart records one incident and stays quiet"
}

# --- ENGINE ---
test_below_threshold_silent_but_durable
test_threshold_announces_with_context
test_distinct_classes_isolated
test_unknown_class_refused
test_debounce_collapses_storm
test_no_debounce_counts_every_event
test_threshold_override_and_fallback
test_ordinal_formatting
test_detail_sanitized
test_class_known_predicate
# --- SITE: fm-guard.sh ---
test_guard_watcher_down_announces_at_threshold
test_guard_watcher_down_silent_below_threshold
test_guard_healthy_records_nothing
test_guard_episode_collapses_rapid_repeats
test_guard_distinct_episodes_each_record
test_guard_read_only_records_nothing
test_guard_worktree_tangle_announces_at_threshold
# --- SITE: fm-turnend-guard.sh ---
test_turnend_announces_at_threshold
test_turnend_silent_below_threshold
test_turnend_no_inflight_records_nothing
# --- SITE: fm-watch-arm.sh ---
test_arm_failed_announces_at_threshold
test_arm_failed_silent_below_threshold
test_arm_forced_restart_announces_at_threshold
test_arm_forced_restart_silent_below_threshold
