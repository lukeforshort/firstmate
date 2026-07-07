#!/usr/bin/env bash
# shellcheck shell=bash
# Single source of truth for the fork push target of firstmate's OWN repo.
#
# The captain's standing rule (data/captain.md, 2026-07-07): firstmate's own
# changes go ONLY to the captain's own fork (e.g. lukeforshort/firstmate), never
# to the upstream owner (kunchenguid/firstmate). The no-mistakes gate derives its
# push/PR target from the repo's origin remote, which for a clone of the upstream
# is the upstream, so a bare `no-mistakes init` targets upstream and 403s. The
# fix is to always feed init the fork URL via `--fork-url`.
#
# This lib holds that URL in exactly ONE place - the local, gitignored
# config/fork-url file - and exposes the accessors every init call site reads, so
# the fork target is defined once and referenced everywhere. Absent config/fork-url
# => empty => today's bare-init behavior, so a non-fork user is unaffected.
#
# Usage: . bin/fm-fork-url-lib.sh   (needs FM_ROOT/FM_HOME or FM_CONFIG_OVERRIDE
# set the same way the sourcing script sets them; falls back to this repo root).

# fm_fork_url [config-dir]
# Print the configured fork URL for firstmate's own repo, or nothing when unset.
# Reads the first non-empty, non-comment line of <config-dir>/fork-url. The config
# dir defaults to FM_CONFIG_OVERRIDE, else $FM_HOME/config, else this repo's config.
fm_fork_url() {
  local config_dir=${1:-} file line
  if [ -z "$config_dir" ]; then
    if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
      config_dir="$FM_CONFIG_OVERRIDE"
    else
      local self_dir root home
      self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
      root="${FM_ROOT_OVERRIDE:-$(cd "$self_dir/.." && pwd)}"
      home="${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}"
      config_dir="$home/config"
    fi
  fi
  file="$config_dir/fork-url"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    # Trim surrounding whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
    return 0
  done < "$file"
  return 0
}

# fm_is_firstmate_own_repo <repo-dir>
# Return 0 when <repo-dir>'s origin remote points at firstmate's own repository
# (repo component "firstmate", ignoring a trailing .git), the ONLY case whose
# init must use the fork URL. Any other project - which has its own origin - is
# left to bare init. Returns non-zero when there is no origin, the URL cannot be
# read, or the repo component is not "firstmate".
fm_is_firstmate_own_repo() {
  local repo_dir=${1:-} url repo_component
  [ -n "$repo_dir" ] || return 1
  url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  # Strip a trailing slash, then take the last path/colon-separated component.
  url="${url%/}"
  repo_component="${url##*/}"
  repo_component="${repo_component##*:}"
  repo_component="${repo_component%.git}"
  [ "$repo_component" = firstmate ]
}

# When executed directly (not sourced), print the configured fork URL, so brief
# guidance and other scripts can shell out to it as the single accessor.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_fork_url "$@"
fi
