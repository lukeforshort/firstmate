#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
mkdir -p "$STATE"

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# fm_pid_starttime_ticks <pid>
# Field 22 of /proc/<pid>/stat: starttime in clock ticks since boot, computed
# once by the kernel at process creation from a monotonic clock - never
# re-derived from wall time on a later read. Comm (field 2) is parenthesized
# and may itself contain spaces or ')', so this strips through the LAST ')'
# rather than assuming a fixed field count from the start of the line.
fm_pid_starttime_ticks() {
  local pid=$1 stat rest val
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
  [ -n "$stat" ] || return 1
  rest=${stat##*)}
  # shellcheck disable=SC2086  # deliberate word-splitting to index remaining fields
  set -- $rest
  # $1 here is field 3 (state); starttime is field 22, the 20th field from here.
  [ "$#" -ge 20 ] || return 1
  shift 19
  val=$1
  case "$val" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$val"
}

# fm_pid_identity is the sole owner of "is this the same process, not a
# reused pid" comparisons across bin/fm-watch-arm.sh, bin/fm-turnend-guard.sh,
# and bin/fm-guard.sh (via fm_watcher_lock_matches_pid and fm_arm_in_progress
# below). It used to compare `ps`'s lstart wall-clock string plus command.
# Measured on a WSL2 host: /proc's boot-time reference (btime) itself drifts
# (~1s per ~20s of wall time, confirmed via two /proc/stat samples 20s apart
# and a same-pid lstart shift over the same window) even though
# `timedatectl` reports the clock as synchronized. lstart is derived from
# btime on every read, so a live, never-restarted process's own recorded
# lstart silently walked forward until it no longer matched a fresh read -
# not a transient hiccup a retry can fix, since the drift is monotonic and
# every later read keeps disagreeing more, not less.
# On Linux (including WSL2), starttime in jiffies-since-boot (read via
# fm_pid_starttime_ticks above) is immune to this: the kernel stores it once
# at process creation and it is never recomputed from wall time afterward.
# Hosts without /proc (macOS) fall back to the original lstart+command form;
# they are not known to exhibit this drift.
fm_pid_identity() {
  local pid=$1 start command_out out
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -r "/proc/$pid/stat" ]; then
    start=$(fm_pid_starttime_ticks "$pid") || return 1
    [ -n "$start" ] || return 1
    command_out=$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null) || return 1
    [ -n "$command_out" ] || return 1
    printf 'start:%s command:%s\n' "$start" "$(printf '%s' "$command_out" | sed 's/^[[:space:]]*//')"
    return 0
  fi
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# fm_pid_identity forks `ps` (and, on Linux, reads /proc) to compute the
# comparison identity; under a heavily loaded fleet that fork can transiently
# fail or return empty output for a pid that is, in fact, still alive and
# unchanged. This bounded retry covers exactly that generic subprocess-fork
# hazard. It is a narrower fix than it first looks: an earlier turn-end guard
# false alarm on a watcher healthy for ~15 minutes, whose lock content
# matched on an immediate manual recheck, turned out to be the /proc
# btime-drift bug fm_pid_identity itself now fixes (see its own comment) -
# a persistent, monotonically-growing mismatch that a same-moment retry
# cannot paper over, since every read keeps disagreeing more, not less. Only
# an EMPTY/failed read is retried here, and only while the pid stays alive; a
# read that succeeds but genuinely mismatches (a different identity, e.g. a
# reused pid) is never retried and fails immediately, so this cannot mask a
# real identity mismatch, only a flaky subprocess invocation.
fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity current_identity attempt
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  attempt=0
  while :; do
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
    [ -n "$current_identity" ] && break
    attempt=$((attempt + 1))
    [ "$attempt" -lt "${FM_PID_IDENTITY_RETRIES:-3}" ] || return 1
    fm_pid_alive "$pid" || return 1
    sleep "${FM_PID_IDENTITY_RETRY_DELAY:-0.05}"
  done
  [ "$current_identity" = "$lock_identity" ]
}

FM_WATCHER_HEALTHY_PID=
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid age
  FM_WATCHER_HEALTHY_PID=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  age=$(fm_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  return 0
}

# fm-watch.sh claims the singleton lock's pid file first (inside
# fm_lock_try_create), then writes fm-home/watcher-path/pid-identity as three
# separate, non-atomic steps before it ever reaches its first beacon touch. A
# health check sampled in that window sees a live, correctly-held lock whose
# identity trio is still incomplete, so fm_watcher_healthy legitimately reads
# unhealthy even though a watcher is genuinely, successfully arming - not
# missing. The arm marker below is a second, independent liveness signal for
# exactly that window: bin/fm-watch-arm.sh writes it the instant it starts
# (before any restart kill-wait, fork, or confirm polling) and refreshes it on
# every loop iteration until it exits, via a single EXIT trap that always
# clears it. A stale marker (no touch for its grace window) means the arming
# process itself has stalled, not merely that the watcher it is starting
# hasn't finished yet - that case must still read as not-in-progress, so a
# genuinely wedged or dead arm is never masked.

# fm_arm_marker_write <state-dir> <home>
# Best-effort: a write failure never blocks the arm that calls it.
fm_arm_marker_write() {
  local state=$1 home=$2 dir tmp
  dir="$state/.watch-arm.marker"
  tmp=$(mktemp -d "${dir}.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "${BASHPID:-$$}" > "$tmp/pid" 2>/dev/null || true
  printf '%s\n' "$home" > "$tmp/fm-home" 2>/dev/null || true
  fm_pid_identity "${BASHPID:-$$}" > "$tmp/pid-identity" 2>/dev/null || true
  rm -rf "$dir" 2>/dev/null || true
  if ! mv "$tmp" "$dir" 2>/dev/null; then
    rm -rf "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

# fm_arm_marker_touch <state-dir>
# Refresh the marker's mtime; call once per polling-loop iteration so a live,
# looping arm never reads as stale even under a small FM_ARM_GRACE.
fm_arm_marker_touch() {
  local state=$1
  touch "$state/.watch-arm.marker" 2>/dev/null || true
}

# fm_arm_marker_clear <state-dir>
# Removes the marker only if it still names THIS process, so a slower
# concurrent arm's still-valid marker (overwritten by a second, faster arm's
# fm_arm_marker_write) is never deleted out from under it.
fm_arm_marker_clear() {
  local state=$1 dir pid
  dir="$state/.watch-arm.marker"
  [ -d "$dir" ] || return 0
  pid=$(cat "$dir/pid" 2>/dev/null || true)
  [ "$pid" = "${BASHPID:-$$}" ] || return 0
  rm -rf "$dir" 2>/dev/null || true
}

# fm_arm_in_progress <state-dir> [grace] [home]
# True iff a live process matches the arm marker's recorded identity (the same
# identity discipline as fm_watcher_healthy: a dead or reused pid, or a
# foreign home, never counts) AND the marker itself was touched within grace.
# Callers (bin/fm-turnend-guard.sh, bin/fm-guard.sh) OR this with their own
# watcher-health check so a healthy watcher and an actively-arming one are
# both read as "supervision is not missing".
fm_arm_in_progress() {
  local state=$1 grace=${2:-${FM_ARM_GRACE:-30}} home=${3:-$FM_HOME} dir pid mhome midentity current_identity age
  dir="$state/.watch-arm.marker"
  [ -d "$dir" ] || return 1
  pid=$(cat "$dir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  mhome=$(cat "$dir/fm-home" 2>/dev/null || true)
  [ "$mhome" = "$home" ] || return 1
  midentity=$(cat "$dir/pid-identity" 2>/dev/null || true)
  [ -n "$midentity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$midentity" ] || return 1
  age=$(fm_path_age "$dir")
  [ "$age" -lt "$grace" ]
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

fm_lock_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  FM_LOCK_OWNER_DIR=
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_prepare_owner "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_pid_alive "$actual_pid"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

fm_lock_try_acquire() {
  local lockdir=$1 pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=

  if fm_lock_try_create "$lockdir"; then
    return 0
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! fm_lock_try_acquire "$steal"; then
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}
