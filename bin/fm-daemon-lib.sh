# shellcheck shell=bash
# Shared away-mode (afk) supervise-daemon liveness helpers.
#
# One owner for the daemon-liveness contract: the daemon lock/pidfile/beacon
# names, "is the daemon lock held by a live daemon process", and the daemon
# beacon freshness. It mirrors the watcher's own liveness idiom - the watcher
# touches state/.last-watcher-beat every poll and bin/fm-supervision-lib.sh reads
# it; the daemon touches state/.last-daemon-beat every cycle and this lib reads
# it - so a silently dead or wedged daemon is detected instead of assumed alive.
#
# Sourced by:
#   bin/fm-afk-start.sh          - startup dedupe (lock held by a live daemon)
#   bin/fm-supervise-daemon.sh   - the beacon name it touches every cycle
#   bin/fm-guard.sh              - the afk-daemon-down alarm banner
#   bin/fm-session-start.sh      - the recovery-path AFK liveness read
#
# Requires fm-wake-lib.sh's fm_pid_alive / fm_pid_identity / fm_path_age. Source
# it here only when a caller has not already, so double-sourcing is cheap.
if ! declare -F fm_pid_alive >/dev/null 2>&1; then
  _FM_DAEMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_DAEMON_LIB_DIR/fm-wake-lib.sh"
else
  _FM_DAEMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Canonical daemon state-file names (one owner). Callers compose them against
# their own resolved state dir.
FM_DAEMON_LOCK_NAME=".supervise-daemon.lock"
# shellcheck disable=SC2034 # FM_DAEMON_BEAT_NAME is read by fm-supervise-daemon.sh after sourcing.
FM_DAEMON_BEAT_NAME=".last-daemon-beat"
# The daemon script itself, used as the ps-command fallback identity when a lock
# predates pid-identity files. Resolves to bin/fm-supervise-daemon.sh alongside
# this lib, matching fm-afk-start.sh's own $DAEMON path.
FM_DAEMON_SCRIPT="$_FM_DAEMON_LIB_DIR/fm-supervise-daemon.sh"

# fm_daemon_lock_owner <lock-path>
# Resolve the owner directory of the portable daemon lock (a symlink to an owner
# dir, or a plain lock dir for the legacy directory-lock form). Prints the owner
# dir on stdout; returns 1 when the lock is absent.
fm_daemon_lock_owner() {
  local lock=$1 owner
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$lock")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$lock" ] || return 1
  printf '%s\n' "$lock"
}

# fm_daemon_pid_matches <pid> <owner-dir>
# 0 when <pid> is genuinely this home's daemon: its recorded identity matches the
# live process (preferred), or - for a lock with no pid-identity file - its
# command line still names the daemon script. Guards against a recycled pid.
fm_daemon_pid_matches() {
  local pid=$1 owner=$2 identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$FM_DAEMON_SCRIPT"*|*"fm-supervise-daemon.sh"*) return 0 ;;
  esac
  return 1
}

# fm_daemon_lock_pid <lock-path>
# Print the pid recorded in the daemon lock's owner dir (empty if none).
fm_daemon_lock_pid() {
  local owner
  owner=$(fm_daemon_lock_owner "$1") || return 1
  cat "$owner/pid" 2>/dev/null || true
}

# fm_daemon_lock_held_by_live_daemon <lock-path>
# 0 exactly when the lock is held by a live, identity-matched daemon process.
fm_daemon_lock_held_by_live_daemon() {
  local owner pid
  owner=$(fm_daemon_lock_owner "$1") || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_daemon_pid_matches "$pid" "$owner"
}

# fm_daemon_status <state-dir> [grace-seconds]
# Populate, for the state dir at $1:
#   FM_DAEMON_AFK          true/false - state/.afk present (away mode requested)
#   FM_DAEMON_ALIVE        true/false - lock held by a live daemon process
#   FM_DAEMON_BEACON_FRESH true/false - state/.last-daemon-beat within grace
#   FM_DAEMON_BEACON_DESC  human-readable beacon age ("never" if absent)
# grace defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh. Returns 0.
fm_daemon_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} lock beat age
  FM_DAEMON_AFK=false
  FM_DAEMON_ALIVE=false
  FM_DAEMON_BEACON_FRESH=false
  FM_DAEMON_BEACON_DESC=never

  [ -e "$state/.afk" ] && FM_DAEMON_AFK=true

  lock="$state/$FM_DAEMON_LOCK_NAME"
  fm_daemon_lock_held_by_live_daemon "$lock" && FM_DAEMON_ALIVE=true

  beat="$state/$FM_DAEMON_BEAT_NAME"
  if [ -e "$beat" ]; then
    age=$(fm_path_age "$beat")
    # shellcheck disable=SC2034 # FM_DAEMON_BEACON_DESC is read by callers after this returns.
    FM_DAEMON_BEACON_DESC="${age}s ago"
    [ "$age" -lt "$grace" ] && FM_DAEMON_BEACON_FRESH=true
  fi
  return 0
}

# fm_daemon_down <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: away mode is requested
# (state/.afk present) but the daemon is not proven alive - its process is gone
# (the lock names no live daemon) OR its liveness beacon has gone stale (a wedged
# daemon that stopped touching it). Exit 1 (false) otherwise, including whenever
# afk is inactive. Not gated on in-flight count: away mode keeps the daemon armed
# for X mode and late crew reports even with an empty queue, so a dead daemon
# under afk is a fault regardless.
fm_daemon_down() {
  fm_daemon_status "$@"
  [ "$FM_DAEMON_AFK" = true ] || return 1
  [ "$FM_DAEMON_ALIVE" = false ] && return 0
  [ "$FM_DAEMON_BEACON_FRESH" = false ] && return 0
  return 1
}
