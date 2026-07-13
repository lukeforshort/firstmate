# shellcheck shell=bash
# Shared supervision-symptom recurrence tracker.
#
# Some supervision failures recur: an arm that reports FAILED though a watcher is
# alive, a turn-end guard that blocks though the lock looks healthy, a watcher
# reported down while work is in flight, a hand-forced restart to clear a wedge.
# The management audit (data/mgmt-audit-2026-07-10, finding B2/L4) found each was
# re-learned as a fresh quirk and hand-fixed with `--restart` again and again,
# with no signal that it was the SAME symptom recurring and deserved a structural
# fix instead of another workaround.
#
# This library turns each existing detection site into a durable, self-announcing
# counter. It adds NO new detection: callers invoke fm_symptom_record only where
# the symptom is already detected. A small append-only log per symptom class lives
# under state/ (.symptom-<class>.log), one line per incident
# (<epoch>\t<iso-datetime>\t<detail>). The count is the line count; the first
# line's date is the "since" date. When a class reaches FM_SYMPTOM_THRESHOLD
# occurrences, fm_symptom_record prints ONE announcement line naming the count,
# the first-seen date, and the log path, telling the supervising agent to file a
# structural fix task per AGENTS.md instead of hand-applying the same workaround.
# Below threshold it stays silent, so normal operation adds no noise. Distinct
# classes count in separate logs, so they never bleed together.
#
# Scripts write to state/ but NEVER to the backlog: the announcement is the loud
# self-report; the supervising agent files the task per AGENTS.md.
#
# Overrides (all optional, defaulted): FM_SYMPTOM_THRESHOLD (default 3),
# FM_SYMPTOM_DEBOUNCE_SECS (default 0; per-call third arg wins), FM_SYMPTOM_NOW
# (epoch override for deterministic tests). State dir resolves from
# FM_STATE_OVERRIDE, then STATE, then $FM_HOME/state.

FM_SYMPTOM_THRESHOLD_DEFAULT=3

# Coarse, stable symptom classes. Kept a fixed vocabulary so counts survive across
# sessions and a typo can never mint a phantom class. arm-failed, forced-restart,
# guard-blind-turn, and worktree-tangle are wired today; stale-escalation is a
# reserved name for the wedge-timer site that already carries its own in-session
# escalation idiom. guard-blind-turn covers the 2026-07-10 identity-check race:
# the turn-end guard reports "no live watcher holds this home lock" seconds after
# a successful arm while a watcher with a fresh beacon does hold it.
_FM_SYMPTOM_CLASSES='arm-failed forced-restart guard-blind-turn watcher-down worktree-tangle stale-escalation'

# Current epoch, honoring the FM_SYMPTOM_NOW test override.
fm_symptom_now() {
  if [ -n "${FM_SYMPTOM_NOW:-}" ]; then
    printf '%s\n' "$FM_SYMPTOM_NOW"
  else
    date +%s
  fi
}

# 0 if <class> is one of the known coarse classes; 1 otherwise.
fm_symptom_class_known() {
  local c=$1
  case " $_FM_SYMPTOM_CLASSES " in
    *" $c "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Portable epoch -> ISO datetime (GNU date -d @, BSD date -r; epoch as last resort).
fm_symptom_iso() {
  local epoch=$1
  date -d "@$epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || date -r "$epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || printf '%s' "$epoch"
}

# English ordinal: 1 -> 1st, 2 -> 2nd, 3 -> 3rd, 4 -> 4th, 11 -> 11th, ...
fm_symptom_ordinal() {
  local n=$1 suffix
  case $(( n % 100 )) in
    11|12|13) suffix=th ;;
    *)
      case $(( n % 10 )) in
        1) suffix=st ;;
        2) suffix=nd ;;
        3) suffix=rd ;;
        *) suffix=th ;;
      esac
      ;;
  esac
  printf '%s%s\n' "$n" "$suffix"
}

# fm_symptom_record <class> [detail] [debounce-secs]
# Records one incident for <class> under state/.symptom-<class>.log, then prints
# ONE announcement line to stdout IFF the class has now reached the threshold.
# With a positive debounce, an incident whose class last fired within that many
# seconds is collapsed into the same episode: no new line, no announcement (this
# is what keeps the pull-based guard, which runs on every fleet action, from
# inflating a storm into a false recurrence). Discrete once-per-event sites pass
# no debounce so every occurrence counts.
# Returns 0 on a recorded incident, 1 when debounced, 2 on an unknown class.
fm_symptom_record() {
  local class=$1 detail=${2:-} debounce=${3:-${FM_SYMPTOM_DEBOUNCE_SECS:-0}}
  local state threshold log now iso last_epoch count first_line first_date

  if ! fm_symptom_class_known "$class"; then
    printf 'fm_symptom_record: unknown symptom class: %s\n' "$class" >&2
    return 2
  fi

  state="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
  threshold=${FM_SYMPTOM_THRESHOLD:-$FM_SYMPTOM_THRESHOLD_DEFAULT}
  case "$threshold" in ''|*[!0-9]*) threshold=$FM_SYMPTOM_THRESHOLD_DEFAULT ;; esac
  case "$debounce" in ''|*[!0-9]*) debounce=0 ;; esac

  mkdir -p "$state" 2>/dev/null || true
  log="$state/.symptom-$class.log"
  now=$(fm_symptom_now)

  if [ "$debounce" -gt 0 ] && [ -s "$log" ]; then
    last_epoch=$(tail -n 1 "$log" 2>/dev/null | cut -f1)
    case "$last_epoch" in
      ''|*[!0-9]*) ;;
      *) [ $(( now - last_epoch )) -lt "$debounce" ] && return 1 ;;
    esac
  fi

  detail=$(printf '%s' "$detail" | LC_ALL=C tr '\t\r\n' '   ')
  iso=$(fm_symptom_iso "$now")
  printf '%s\t%s\t%s\n' "$now" "$iso" "$detail" >> "$log" 2>/dev/null || return 0

  count=$(wc -l < "$log" 2>/dev/null | tr -d '[:space:]')
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$count" -ge "$threshold" ] || return 0

  first_line=$(head -n 1 "$log" 2>/dev/null)
  first_date=$(printf '%s' "$first_line" | cut -f2 | cut -dT -f1)
  [ -n "$first_date" ] || first_date=$(printf '%s' "$iso" | cut -dT -f1)

  printf "RECURRING SUPERVISION SYMPTOM '%s': %s occurrence since %s (prior incidents logged in %s). Same symptom re-detected - file a structural fix ship task per AGENTS.md instead of hand-applying the workaround again.\n" \
    "$class" "$(fm_symptom_ordinal "$count")" "$first_date" "$log"
  return 0
}
