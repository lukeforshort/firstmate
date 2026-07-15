#!/usr/bin/env bash
# fm-mem-guard.sh - dispatch-time memory headroom tripwire. Source this file
# and call fm_mem_guard_check before any fm-spawn.sh side effect (window,
# worktree lease, meta, hook install). This is a TRIPWIRE, not a queue: it
# only refuses a single launch attempt so the caller can exit non-zero;
# firstmate's backlog is already the queue and retries the dispatch later.
#
# Background: this machine runs WSL2 under a deliberately tight memory cap
# set in /mnt/c/Users/snydi/.wslconfig (read live if you need the cap value;
# it changes, never hard-code it here). Two 2026-07-10 OOM incidents killed
# the whole fleet (tmux server, no-mistakes daemon, dbus) from concurrent
# dispatch with no headroom check.
#
# Measurement: used% = (MemTotal - MemAvailable) / MemTotal * 100, read
# straight from /proc/meminfo with bash builtins only (no forks, no jq/awk).
#
# FM_SPAWN_MEM_MAX_PCT - defer threshold, percent of MemTotal used. Default 80.
#   A set-but-unparseable value warns on stderr and falls back to the default.
# FM_SPAWN_MEM_FORCE=1 - skip the check entirely, for a captain-ordered
#   emergency dispatch. Only the literal 1 bypasses; any other set value (a
#   typo'd true/yes) warns on stderr and is ignored, so the check still runs.
# FM_MEMINFO_PATH_OVERRIDE - read this path instead of /proc/meminfo; the
#   hermetic test seam, never set outside tests.
#
# Fails OPEN: a missing or unparseable meminfo file lets the spawn proceed.
# The tripwire must never brick dispatch on a weird environment.

fm_mem_guard_check() {
  local meminfo total avail key val pct threshold used force

  force="${FM_SPAWN_MEM_FORCE-0}"
  case "$force" in
    1) return 0 ;;
    ''|0) ;;
    *) echo "WARNING: FM_SPAWN_MEM_FORCE='${force}' ignored - only FM_SPAWN_MEM_FORCE=1 bypasses the memory headroom check" >&2 ;;
  esac

  meminfo="${FM_MEMINFO_PATH_OVERRIDE:-/proc/meminfo}"
  [ -r "$meminfo" ] || return 0

  total=
  avail=
  while IFS=: read -r key val; do
    case "$key" in
      MemTotal) total=${val%kB}; total=${total// /} ;;
      MemAvailable) avail=${val%kB}; avail=${avail// /} ;;
    esac
    { [ -z "$total" ] || [ -z "$avail" ]; } || break
  done < "$meminfo"

  case "$total" in ''|*[!0-9]*) return 0 ;; esac
  case "$avail" in ''|*[!0-9]*) return 0 ;; esac
  [ "$total" -gt 0 ] || return 0

  used=$((total - avail))
  pct=$((used * 100 / total))

  threshold="${FM_SPAWN_MEM_MAX_PCT-80}"
  case "$threshold" in
    ''|*[!0-9]*)
      echo "WARNING: FM_SPAWN_MEM_MAX_PCT='${threshold}' is not a non-negative integer - falling back to the default 80% memory headroom threshold" >&2
      threshold=80
      ;;
  esac

  if [ "$pct" -ge "$threshold" ]; then
    echo "DEFERRED: memory headroom tripwire tripped - used ${pct}% >= threshold ${threshold}%; firstmate should retry this dispatch once headroom recovers (bypass with FM_SPAWN_MEM_FORCE=1 for a captain-ordered emergency dispatch)" >&2
    return 1
  fi
  return 0
}
