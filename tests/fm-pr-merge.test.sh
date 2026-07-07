#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
# Red-PR gate (AGENTS.md section 7 "never merge a red PR even under yolo"):
#   (i) a failing check refuses before gh-axi pr merge
#   (j) a pending check refuses before gh-axi pr merge, even with --allow-red
#   (k) a green rollup merges
#   (l) an empty rollup with --allow-red merges (documented no-CI-repo case)
#   (m) an empty rollup without --allow-red refuses (fail-closed)
#   (n) mergeState BLOCKED refuses even with a green rollup
#   (o) an unreadable pr view refuses (fail-closed)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, answering the red-PR
# gate's `pr view --json statusCheckRollup,mergeStateStatus` query from a
# per-case rollup payload, and a gh mock answering headRefOid for fm-pr-check.sh's
# pr_head lookup. Args: case_dir head_sha
#
# The rollup payload comes from $case_dir/rollup.json when present, else defaults
# to a single green (COMPLETED/SUCCESS) check with a CLEAN mergeState, so any test
# that does not exercise the gate still merges. Write rollup.json with
# set_rollup before running the merge to drive the gate.
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_AXI_LOG"
# The red-PR gate reads the PR's check rollup + mergeState via pr view --json.
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
  case " \$* " in
    *--json*statusCheckRollup*)
      if [ -f "$case_dir/rollup.json" ]; then
        cat "$case_dir/rollup.json"
      else
        printf '%s\n' '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN"}'
      fi
      exit 0
      ;;
  esac
fi
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Write a rollup payload the gate mock will serve for pr view --json. Arg 2 is a
# raw JSON object for {statusCheckRollup, mergeStateStatus}.
set_rollup() {
  local case_dir=$1 json=$2
  printf '%s\n' "$json" > "$case_dir/rollup.json"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_AXI_LOG"
# Green rollup so the red-PR gate passes and the merge call is reached.
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "view" ]; then
  case " \$* " in
    *--json*statusCheckRollup*)
      printf '%s\n' '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeStateStatus":"CLEAN"}'
      exit 0
      ;;
  esac
fi
case "\${1:-} \${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'no meta for task missing-x1' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "malformed-url: refusal did not explain the expected URL shape"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'must not override --repo parsed from PR URL' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126/ \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_failing_check_refuses_merge() {
  local case_dir rc
  case_dir=$(make_case gate-failing-check)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
  set_rollup "$case_dir" \
    '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}],"mergeStateStatus":"UNSTABLE"}'
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/30 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gate-failing-check: fm-pr-merge should refuse a red PR"
  assert_grep 'failing checks: ci' "$case_dir/stderr" \
    "gate-failing-check: refusal did not name the failing check"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "gate-failing-check: gh-axi pr merge was invoked for a red PR"
  pass "fm-pr-merge refuses a PR with a failing check before merging"
}

test_pending_check_refuses_merge_even_with_allow_red() {
  local case_dir rc
  case_dir=$(make_case gate-pending-check)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
  set_rollup "$case_dir" \
    '{"statusCheckRollup":[{"name":"ci","status":"IN_PROGRESS"}],"mergeStateStatus":"UNKNOWN"}'
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gate-pending-check: fm-pr-merge should refuse a pending PR even with --allow-red"
  assert_grep 'pending checks: ci' "$case_dir/stderr" \
    "gate-pending-check: refusal did not name the pending check"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "gate-pending-check: gh-axi pr merge was invoked for a pending PR"
  pass "fm-pr-merge refuses a PR with a pending check even under --allow-red"
}

test_green_rollup_merges() {
  local case_dir
  case_dir=$(make_case gate-green)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3
  set_rollup "$case_dir" \
    '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"},{"context":"legacy","state":"SUCCESS"}],"mergeStateStatus":"CLEAN"}'
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "gate-green: fm-pr-merge failed on a green PR"

  grep -qxF 'pr merge 32 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "gate-green: gh-axi pr merge was not invoked for a green PR"
  pass "fm-pr-merge merges a PR whose checks are all green"
}

test_empty_rollup_with_allow_red_merges() {
  local case_dir
  case_dir=$(make_case gate-empty-allow-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4
  set_rollup "$case_dir" '{"statusCheckRollup":[],"mergeStateStatus":"CLEAN"}'
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "gate-empty-allow-red: fm-pr-merge failed on empty rollup with --allow-red"

  grep -qxF 'pr merge 33 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "gate-empty-allow-red: gh-axi pr merge was not invoked for the no-CI-repo case"
  pass "fm-pr-merge merges an empty-rollup (no-CI) PR with --allow-red"
}

test_empty_rollup_without_flag_refuses() {
  local case_dir rc
  case_dir=$(make_case gate-empty-no-flag)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5
  set_rollup "$case_dir" '{"statusCheckRollup":[],"mergeStateStatus":"CLEAN"}'
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gate-empty-no-flag: fm-pr-merge should refuse an empty rollup without --allow-red"
  assert_grep 'no configured checks' "$case_dir/stderr" \
    "gate-empty-no-flag: refusal did not explain the empty rollup"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "gate-empty-no-flag: gh-axi pr merge was invoked for an empty rollup without --allow-red"
  pass "fm-pr-merge refuses an empty rollup without --allow-red (fail-closed)"
}

test_blocked_merge_state_refuses() {
  local case_dir rc
  case_dir=$(make_case gate-blocked)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6
  # Green checks but BLOCKED mergeState (e.g. required review missing).
  set_rollup "$case_dir" \
    '{"statusCheckRollup":[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeStateStatus":"BLOCKED"}'
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/35 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gate-blocked: fm-pr-merge should refuse a BLOCKED mergeState"
  assert_grep 'mergeState is BLOCKED' "$case_dir/stderr" \
    "gate-blocked: refusal did not explain the BLOCKED mergeState"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "gate-blocked: gh-axi pr merge was invoked for a BLOCKED PR"
  pass "fm-pr-merge refuses a BLOCKED mergeState even with a green rollup"
}

test_null_rollup_refuses() {
  local case_dir rc
  case_dir=$(make_case gate-null-rollup)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f
  # Valid JSON but no statusCheckRollup array at all (null): must fail-closed,
  # not be mistaken for an empty rollup.
  set_rollup "$case_dir" '{"mergeStateStatus":"CLEAN"}'
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/37 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gate-null-rollup: fm-pr-merge should refuse a null rollup (fail-closed)"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "gate-null-rollup: gh-axi pr merge was invoked for a null rollup"
  pass "fm-pr-merge refuses (fail-closed) when the rollup is null rather than an empty array"
}

test_unreadable_pr_view_refuses() {
  local case_dir fakebin rc
  case_dir=$(make_case gate-unreadable)
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/wt"
  # gh-axi records invocations and records pr= via pr-check's own gh mock, but
  # fails the gate's pr view --json query so the gate reads unreadable output.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case " $* " in
    *--json*statusCheckRollup*) echo "error: could not read PR" >&2 ; exit 1 ;;
  esac
fi
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/36 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gate-unreadable: fm-pr-merge should refuse when pr view is unreadable"
  assert_grep 'could not read PR' "$case_dir/stderr" \
    "gate-unreadable: refusal did not explain the unreadable check state"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "gate-unreadable: gh-axi pr merge was invoked despite unreadable check state"
  pass "fm-pr-merge refuses (fail-closed) when the PR check state is unreadable"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_failing_check_refuses_merge
test_pending_check_refuses_merge_even_with_allow_red
test_green_rollup_merges
test_empty_rollup_with_allow_red_merges
test_empty_rollup_without_flag_refuses
test_blocked_merge_state_refuses
test_null_rollup_refuses
test_unreadable_pr_view_refuses
