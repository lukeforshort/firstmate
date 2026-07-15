#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

# The fleet-state tripwire snapshots the running default session, so
# fm_herdr_lab_prepare cannot provision a lab session on a host where herdr is
# installed but no default server is running. That is host state these tests
# must not change - starting or stopping the captain's default server is the
# very thing the tripwire guards - so report it as a skip precondition,
# alongside the herdr/jq absence gates each real-Herdr test already carries.
herdr_lab_precondition_ok() {
  command -v herdr >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  fm_herdr_lab_fleet_state "fm-lab-precondition-probe-$$" >/dev/null 2>&1
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
