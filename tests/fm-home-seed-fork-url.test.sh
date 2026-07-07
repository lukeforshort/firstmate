#!/usr/bin/env bash
# Tests that bin/fm-home-seed.sh's no-mistakes init path is fork-aware: it passes
# --fork-url from config/fork-url ONLY when the project being initialized is
# firstmate's own repo (origin ends in firstmate), and keeps bare init for every
# other project (which has its own origin). Drives initialize_no_mistakes_project
# directly by sourcing the script (its bottom dispatch is guarded by BASH_SOURCE).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-home-seed-fork-url)

# Build a secondmate home with one project clone under projects/<name>, a
# projects.md registering it as no-mistakes, and a fakebin whose `no-mistakes`
# records how init was invoked. The fork URL lives in the ACTIVE firstmate home's
# config (it is a property of the primary, not inherited per-home), so it is set
# separately by run_init, not here. Echoes the home dir. Args: name origin_url
make_home() {
  local name=$1 origin=$2 home dst fakebin
  home="$TMP_ROOT/$name"
  dst="$home/projects/proj"
  fakebin="$home/fakebin"
  mkdir -p "$home/data" "$fakebin" "$dst"
  # Register proj as no-mistakes so initialize_no_mistakes_project acts on it.
  cat > "$home/data/projects.md" <<'EOF'
- proj [no-mistakes] - fixture project (added 2026-07-01)
EOF
  git init -q "$dst"
  git -C "$dst" remote add origin "$origin"
  # no-mistakes mock: log init invocations verbatim; doctor is a no-op success.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "init" ]; then
  printf '%s\n' "$*" >> "$FM_TEST_NM_LOG"
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$home"
}

# Source fm-home-seed.sh in a subshell with the env set, then run
# initialize_no_mistakes_project so its fork-aware branch is exercised. Runs the
# proj as "newly created" (created=1) so init actually fires. The ACTIVE firstmate
# home is a sibling of the secondmate home, so validate_project_destination does
# not refuse the seeded project for resolving inside the active home.
# Second arg, when set, is the fork URL to place in the ACTIVE home's config.
run_init() {
  local home=$1 fork=${2:-} active_home
  active_home=$(mktemp -d "$TMP_ROOT/active-home.XXXXXX")
  if [ -n "$fork" ]; then
    mkdir -p "$active_home/config"
    printf '%s\n' "$fork" > "$active_home/config/fork-url"
  fi
  (
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$active_home" \
    FM_TEST_NM_LOG="$home/nm.log" \
    PATH="$home/fakebin:$PATH"
    export FM_ROOT_OVERRIDE FM_HOME FM_TEST_NM_LOG PATH
    # shellcheck source=bin/fm-home-seed.sh
    . "$ROOT/bin/fm-home-seed.sh"
    initialize_no_mistakes_project "$home" proj 1
  )
}

test_own_repo_with_fork_url_uses_fork_flag() {
  local home
  home=$(make_home own-with-fork https://github.com/kunchenguid/firstmate.git)
  : > "$home/nm.log"
  run_init "$home" https://github.com/lukeforshort/firstmate.git \
    || fail "own-with-fork: init failed"
  grep -qxF 'init --fork-url https://github.com/lukeforshort/firstmate.git' "$home/nm.log" \
    || fail "own-with-fork: no-mistakes init did not use --fork-url for firstmate's own repo"
  pass "fm-home-seed init uses --fork-url for firstmate's own repo when config/fork-url is set"
}

test_project_repo_uses_bare_init() {
  local home
  home=$(make_home other-project https://github.com/someone/some-project.git)
  : > "$home/nm.log"
  run_init "$home" https://github.com/lukeforshort/firstmate.git \
    || fail "other-project: init failed"
  grep -qxF 'init' "$home/nm.log" \
    || fail "other-project: bare no-mistakes init was not invoked"
  assert_no_grep '--fork-url' "$home/nm.log" \
    "other-project: --fork-url leaked into a non-firstmate project's init"
  pass "fm-home-seed keeps bare init for a project with its own origin"
}

test_own_repo_without_fork_url_stays_bare() {
  local home
  home=$(make_home own-no-fork https://github.com/kunchenguid/firstmate.git)
  : > "$home/nm.log"
  run_init "$home" || fail "own-no-fork: init failed"
  grep -qxF 'init' "$home/nm.log" \
    || fail "own-no-fork: bare no-mistakes init was not invoked"
  assert_no_grep '--fork-url' "$home/nm.log" \
    "own-no-fork: --fork-url passed with no config/fork-url set"
  pass "fm-home-seed stays bare for firstmate's own repo when config/fork-url is unset"
}

test_own_repo_with_fork_url_uses_fork_flag
test_project_repo_uses_bare_init
test_own_repo_without_fork_url_stays_bare
