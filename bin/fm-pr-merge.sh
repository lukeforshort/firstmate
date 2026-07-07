#!/usr/bin/env bash
# Merge a task's PR, always recording pr= and any available pr_head= into
# state/<id>.meta first via bin/fm-pr-check.sh, so bin/fm-teardown.sh's
# landed-check has a PR reference to verify a squash merge against.
#
# Why this exists: the normal trigger for running fm-pr-check.sh is the crew's
# `done: PR <url> checks green` line, which no-mistakes only emits once its CI
# step turns green. Repos that intentionally run no CI on PRs (CI only on
# pushes to the default branch) never emit that line, so a merge performed by
# hand-running `gh-axi pr merge` - the common shape of a yolo-authorized merge -
# can skip the recording step entirely. Teardown then has nothing to look up for
# a squash-merge-then-delete-branch flow and false-refuses provably landed work.
# This script makes recording part of the merge itself, so it cannot be skipped
# by omission. Use it for every PR merge (captain-requested or yolo-authorized),
# in place of calling `gh-axi pr merge` directly.
#
# gh-axi pr merge expects a PR number and --repo <owner>/<repo>; it does not
# parse a full https://github.com/<owner>/<repo>/pull/<n> URL. This script
# parses the URL and invokes gh-axi in the form it accepts.
#
# Merge method: defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. An explicit
# caller method is never overridden.
# Extra args must not include --repo or -R because the repo is parsed from the
# PR URL.
#
# Red-PR gate: before merging, this script reads the PR's check rollup and
# mergeState and REFUSES (non-zero exit) if any check is failing or still
# pending, or if mergeState is BLOCKED/DIRTY. This makes AGENTS.md section 7's
# "Never merge a red PR even under yolo" an enforced gate, not just prose. The
# gate is fail-closed: an unreadable rollup, unknown mergeState, or partial data
# refuses rather than proceeds. A legitimately empty rollup - a repo with zero
# configured checks, such as the captain's own fork today - is the ONE case a
# check-less merge is expected, and it requires an explicit --allow-red flag so
# the common "checks are configured but I could not read them" path never
# silently passes. --allow-red permits an empty rollup only; it never overrides
# a rollup that actually reports a failing or pending check.
#
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--allow-red] [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ID=${1:?usage: fm-pr-merge.sh <task-id> <pr-url> [--allow-red] [-- <extra gh-axi pr merge args>]}
URL=${2:?usage: fm-pr-merge.sh <task-id> <pr-url> [--allow-red] [-- <extra gh-axi pr merge args>]}
shift 2

ALLOW_RED=0
if [ "${1:-}" = "--allow-red" ]; then
  ALLOW_RED=1
  shift
fi
[ "${1:-}" = "--" ] && shift

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META; refusing to merge without recording pr=" >&2; exit 1; }

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    PR_REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$PR_OWNER" != *- ]]; then
      return 0
    fi
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge args must not override --repo parsed from PR URL (got: $arg)" >&2
        return 1
        ;;
    esac
  done
  return 0
}

# Refuse a red/unmergeable PR. Reads the PR's check rollup and mergeStateStatus
# via gh-axi, then decides fail-closed:
#   - any check FAILURE/ERROR/CANCELLED/TIMED_OUT/ACTION_REQUIRED, or any check
#     not yet concluded (PENDING/QUEUED/IN_PROGRESS/EXPECTED, or a non-COMPLETED
#     status) -> refuse.
#   - mergeStateStatus BLOCKED or DIRTY -> refuse.
#   - an empty rollup (zero configured checks) -> allowed only with --allow-red;
#     without it, refuse, because an empty rollup on a repo that normally has
#     checks must not silently pass.
#   - unreadable/unparseable gh-axi output -> refuse (fail-closed).
# --allow-red widens ONLY the empty-rollup case; it never permits a rollup that
# reports a failing or pending check.
assert_pr_not_red() {
  local view rollup_len merge_state red_checks pending_checks
  if ! view=$(gh-axi pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" \
        --json statusCheckRollup,mergeStateStatus 2>/dev/null); then
    echo "error: could not read PR $PR_NUMBER check state; refusing to merge (fail-closed). Re-run with --allow-red only if this repo has no configured checks." >&2
    return 1
  fi

  # mergeStateStatus: BLOCKED (failing/missing required checks or reviews) and
  # DIRTY (merge conflicts) are hard refusals regardless of the rollup.
  merge_state=$(printf '%s' "$view" | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null) || merge_state=UNKNOWN
  case "$merge_state" in
    BLOCKED|DIRTY)
      echo "error: PR $PR_NUMBER mergeState is $merge_state; refusing to merge." >&2
      return 1
      ;;
  esac

  # A check is "red" if it concluded with anything other than success/neutral/
  # skipped, or (for the legacy status contexts) is in FAILURE/ERROR state.
  red_checks=$(printf '%s' "$view" | jq -r '
    [ .statusCheckRollup[]?
      | select(
          (.conclusion // "" | ascii_upcase) as $c
          | ($c == "FAILURE" or $c == "TIMED_OUT" or $c == "CANCELLED"
             or $c == "ACTION_REQUIRED" or $c == "STARTUP_FAILURE" or $c == "STALE")
          or ((.state // "" | ascii_upcase) as $s | ($s == "FAILURE" or $s == "ERROR"))
        )
      | (.name // .context // "check") ] | join(", ")
  ' 2>/dev/null) || {
    echo "error: could not parse PR $PR_NUMBER check rollup; refusing to merge (fail-closed)." >&2
    return 1
  }
  if [ -n "$red_checks" ]; then
    echo "error: PR $PR_NUMBER has failing checks: $red_checks; refusing to merge." >&2
    return 1
  fi

  # A check is "pending" if it is a checkRun that has not COMPLETED, or a status
  # context still in PENDING/EXPECTED/QUEUED/IN_PROGRESS. --allow-red does NOT
  # override pending checks.
  pending_checks=$(printf '%s' "$view" | jq -r '
    [ .statusCheckRollup[]?
      | select(
          ((.status // "" | ascii_upcase) as $st
           | ($st != "" and $st != "COMPLETED"))
          or ((.state // "" | ascii_upcase) as $s
              | ($s == "PENDING" or $s == "EXPECTED"))
        )
      | (.name // .context // "check") ] | join(", ")
  ' 2>/dev/null) || {
    echo "error: could not parse PR $PR_NUMBER check rollup; refusing to merge (fail-closed)." >&2
    return 1
  }
  if [ -n "$pending_checks" ]; then
    echo "error: PR $PR_NUMBER has pending checks: $pending_checks; refusing to merge." >&2
    return 1
  fi

  # No red and no pending checks. If the rollup is empty, this repo has zero
  # configured checks; only --allow-red permits merging in that case. A MISSING
  # or non-array rollup (null, absent key) is distinct from an empty array and
  # fail-closes: jq's `null | length` is 0, so guard the type before length.
  rollup_len=$(printf '%s' "$view" \
    | jq -r 'if (.statusCheckRollup | type) == "array" then (.statusCheckRollup | length) else "err" end' 2>/dev/null) \
    || rollup_len=err
  case "$rollup_len" in
    ''|err|*[!0-9]*)
      echo "error: could not determine PR $PR_NUMBER check count; refusing to merge (fail-closed)." >&2
      return 1
      ;;
    0)
      if [ "$ALLOW_RED" -ne 1 ]; then
        echo "error: PR $PR_NUMBER has no configured checks; refusing to merge without --allow-red (fail-closed for the no-CI-repo case)." >&2
        return 1
      fi
      ;;
  esac
  return 0
}

parse_pr_url "$URL" || exit 1
reject_repo_overrides "$@" || exit 1

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || { echo "error: fm-pr-check did not record pr=$URL in $META; refusing to merge" >&2; exit 1; }

assert_pr_not_red || exit 1

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" ${merge_args[@]+"${merge_args[@]}"} "$@"
