#!/usr/bin/env bash
# tests/fm-mem-guard.test.sh - unit tests for bin/fm-mem-guard.sh's
# fm_mem_guard_check, the dispatch-time memory headroom tripwire fm-spawn.sh
# calls before any spawn side effect (AGENTS.md task lifecycle, "Spawn").
#
# Hermetic like the JQ_DIR-guard pattern in tests/fm-x-mode.test.sh: every case
# points FM_MEMINFO_PATH_OVERRIDE at a fixture file this suite writes, so the
# real /proc/meminfo (and this machine's actual memory pressure) is never read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-mem-guard.sh
. "$ROOT/bin/fm-mem-guard.sh"

TMP_ROOT=$(fm_test_tmproot fm-mem-guard)
mkdir -p "$TMP_ROOT"

# write_meminfo <path> <total_kB> <avail_kB> writes a minimal fixture with just
# the two fields fm_mem_guard_check reads, in the real file's key/space/unit form.
write_meminfo() {
  local path=$1 total=$2 avail=$3
  {
    printf 'MemTotal:       %s kB\n' "$total"
    printf 'MemFree:        1234 kB\n'
    printf 'MemAvailable:   %s kB\n' "$avail"
  } > "$path"
}

# Isolate every case from the ambient environment: unset the bypass/threshold
# knobs so a leftover export from an earlier case (or the caller's shell)
# never leaks in.
run_check() {
  local meminfo=$1; shift
  ( unset FM_SPAWN_MEM_FORCE FM_SPAWN_MEM_MAX_PCT
    FM_MEMINFO_PATH_OVERRIDE=$meminfo
    export FM_MEMINFO_PATH_OVERRIDE
    for kv in "$@"; do
      export "$kv"
    done
    fm_mem_guard_check
  )
}

test_under_threshold_proceeds() {
  local mi out status
  mi="$TMP_ROOT/under.meminfo"
  write_meminfo "$mi" 100000 21000  # used 79%
  out=$(run_check "$mi") ; status=$?
  [ "$status" -eq 0 ] || fail "under-threshold usage should proceed, got exit $status"
  [ -z "$out" ] || fail "under-threshold usage should print nothing, got: $out"
  pass "fm_mem_guard_check: usage below the default 80% threshold proceeds silently"
}

test_at_threshold_defers() {
  local mi out status
  mi="$TMP_ROOT/at.meminfo"
  write_meminfo "$mi" 100000 20000  # used exactly 80%
  out=$(run_check "$mi" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "at-threshold usage should defer (non-zero exit)"
  printf '%s\n' "$out" | grep -qF 'DEFERRED:' || fail "missing DEFERRED: message, got: $out"
  printf '%s\n' "$out" | grep -qF 'used 80%' || fail "message should state measured used%, got: $out"
  printf '%s\n' "$out" | grep -qF 'threshold 80%' || fail "message should state the threshold, got: $out"
  printf '%s\n' "$out" | grep -qiF 'retry' || fail "message should say firstmate should retry, got: $out"
  pass "fm_mem_guard_check: usage at the threshold defers with a DEFERRED: message and non-zero exit"
}

test_over_threshold_defers() {
  local mi out status
  mi="$TMP_ROOT/over.meminfo"
  write_meminfo "$mi" 100000 5000  # used 95%
  out=$(run_check "$mi" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "over-threshold usage should defer"
  printf '%s\n' "$out" | grep -qF 'DEFERRED:' || fail "missing DEFERRED: message, got: $out"
  pass "fm_mem_guard_check: usage over the threshold defers"
}

test_force_bypass_proceeds() {
  local mi out status
  mi="$TMP_ROOT/force.meminfo"
  write_meminfo "$mi" 100000 1000  # used 99%, would defer without the bypass
  out=$(run_check "$mi" FM_SPAWN_MEM_FORCE=1 2>&1); status=$?
  [ "$status" -eq 0 ] || fail "FM_SPAWN_MEM_FORCE=1 should proceed even under heavy pressure, got exit $status"
  [ -z "$out" ] || fail "forced bypass should print nothing, got: $out"
  pass "fm_mem_guard_check: FM_SPAWN_MEM_FORCE=1 bypasses the check"
}

test_unreadable_meminfo_proceeds() {
  local out status
  out=$(run_check "$TMP_ROOT/does-not-exist.meminfo" 2>&1); status=$?
  [ "$status" -eq 0 ] || fail "unreadable meminfo must fail open (proceed), got exit $status"
  [ -z "$out" ] || fail "fail-open path should print nothing, got: $out"
  pass "fm_mem_guard_check: unreadable /proc/meminfo fails open and proceeds"
}

test_unparseable_meminfo_proceeds() {
  local mi out status
  mi="$TMP_ROOT/garbage.meminfo"
  printf 'not meminfo at all\n' > "$mi"
  out=$(run_check "$mi" 2>&1); status=$?
  [ "$status" -eq 0 ] || fail "unparseable meminfo must fail open (proceed), got exit $status"
  [ -z "$out" ] || fail "fail-open path should print nothing, got: $out"
  pass "fm_mem_guard_check: unparseable meminfo fails open and proceeds"
}

test_custom_threshold_honored() {
  local mi out status
  mi="$TMP_ROOT/custom.meminfo"
  write_meminfo "$mi" 100000 40000  # used 60%
  out=$(run_check "$mi" FM_SPAWN_MEM_MAX_PCT=50 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "60% used should defer against a custom 50% threshold"
  printf '%s\n' "$out" | grep -qF 'threshold 50%' || fail "message should honor the custom threshold, got: $out"

  out=$(run_check "$mi" FM_SPAWN_MEM_MAX_PCT=90 2>&1); status=$?
  [ "$status" -eq 0 ] || fail "60% used should proceed against a custom 90% threshold, got exit $status"
  pass "fm_mem_guard_check: FM_SPAWN_MEM_MAX_PCT overrides the default threshold"
}

test_under_threshold_proceeds
test_at_threshold_defers
test_over_threshold_defers
test_force_bypass_proceeds
test_unreadable_meminfo_proceeds
test_unparseable_meminfo_proceeds
test_custom_threshold_honored
