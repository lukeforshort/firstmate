#!/usr/bin/env bash
# Tests for bin/fm-fork-url-lib.sh: the single source of truth for firstmate's
# OWN-repo fork push target (data/captain.md fork-only delivery rule). Covers the
# config/fork-url accessor and the origin-based own-repo detector that decides
# when `no-mistakes init` must use --fork-url (firstmate's own repo) versus stay
# bare (any other project, which has its own origin).
#
# Matrix:
#   (a) absent config/fork-url => empty (backward-compatible bare-init behavior)
#   (b) present config/fork-url => its trimmed URL, comments/blanks skipped
#   (c) own-repo detector: origin ends in firstmate(.git)? => own repo
#   (d) own-repo detector: an unrelated project origin => NOT own repo
#   (e) own-repo detector: no origin remote => NOT own repo
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-fork-url-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-url-tests)

# shellcheck source=bin/fm-fork-url-lib.sh
. "$LIB"

test_absent_config_is_empty() {
  local config_dir out
  config_dir="$TMP_ROOT/absent/config"
  mkdir -p "$config_dir"
  out=$(fm_fork_url "$config_dir")
  [ -z "$out" ] || fail "absent-config: expected empty, got '$out'"
  pass "fm_fork_url returns empty when config/fork-url is absent"
}

test_present_config_trims_and_skips_comments() {
  local config_dir out
  config_dir="$TMP_ROOT/present/config"
  mkdir -p "$config_dir"
  printf '%s\n' \
    '# fork push target for firstmate own repo' \
    '' \
    '   https://github.com/lukeforshort/firstmate.git   ' > "$config_dir/fork-url"
  out=$(fm_fork_url "$config_dir")
  [ "$out" = 'https://github.com/lukeforshort/firstmate.git' ] \
    || fail "present-config: expected trimmed fork URL, got '$out'"
  pass "fm_fork_url returns the trimmed URL and skips comments/blank lines"
}

test_own_repo_detected_from_origin() {
  local repo
  repo="$TMP_ROOT/own-repo"
  git init -q "$repo"
  git -C "$repo" remote add origin https://github.com/kunchenguid/firstmate.git
  fm_is_firstmate_own_repo "$repo" \
    || fail "own-repo: kunchenguid/firstmate.git origin should be own repo"

  local repo2="$TMP_ROOT/own-repo-fork"
  git init -q "$repo2"
  git -C "$repo2" remote add origin git@github.com:lukeforshort/firstmate
  fm_is_firstmate_own_repo "$repo2" \
    || fail "own-repo: ssh lukeforshort/firstmate origin should be own repo"
  pass "fm_is_firstmate_own_repo detects a firstmate origin (https .git and ssh)"
}

test_unrelated_project_is_not_own_repo() {
  local repo
  repo="$TMP_ROOT/other-project"
  git init -q "$repo"
  git -C "$repo" remote add origin https://github.com/someone/some-project.git
  if fm_is_firstmate_own_repo "$repo"; then
    fail "unrelated-project: an unrelated origin must NOT be treated as own repo"
  fi
  pass "fm_is_firstmate_own_repo rejects an unrelated project origin"
}

test_no_origin_is_not_own_repo() {
  local repo
  repo="$TMP_ROOT/no-origin"
  git init -q "$repo"
  if fm_is_firstmate_own_repo "$repo"; then
    fail "no-origin: a repo with no origin must NOT be treated as own repo"
  fi
  pass "fm_is_firstmate_own_repo rejects a repo with no origin remote"
}

test_absent_config_is_empty
test_present_config_trims_and_skips_comments
test_own_repo_detected_from_origin
test_unrelated_project_is_not_own_repo
test_no_origin_is_not_own_repo
