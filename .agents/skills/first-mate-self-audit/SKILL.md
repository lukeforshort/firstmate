---
name: first-mate-self-audit
description: >
  Conductor self-review for the first-mate agentic stack (WSL/WezTerm/herdr/
  Claude Code/worktrees/MCP). Use when: (1) reviewing first-mate's own system
  or config health, (2) auditing operational or token/model/latency efficiency,
  (3) checking for drift from the declarative source of truth, (4) running a
  periodic conductor health check, (5) auditing in-session conduct such as cache
  economics, delegation discipline, and model tiering. Make sure to invoke this
  whenever the user asks first-mate to "review itself", "check the stack",
  "audit efficiency", "why is this slow/expensive", or mentions drift, token
  cost, cache busts, model tiering, or context bloat - even if they don't say
  the word "audit". READ-ONLY: reports findings, never remediates in the same pass.
user-invocable: true
metadata:
  internal: true
---

# First-Mate Self-Audit

## Capability Overview

This skill lets the first-mate conductor run a structured, **read-only** review of
its own environment and operation, then emit a scored report with a risk rating and
a gated remediation list. It has three halves:

- **Part A — System Health:** is there a single declarative source of truth, does
  reality match it, does it rebuild from zero, and is the agent-governance layer
  (memory file, skills, harnesses) consistent and drift-free?
- **Part B — Operational Efficiency:** token cost, model tiering, context-window
  use, tool-transport cost (MCP vs CLI), parallelism utilisation, and loop economics.
- **Part C — Operational Efficiency (In-Session):** the conductor's own conduct this
  session, measured from logged data: prompt-cache economics, idle-TTL busts,
  delegation discipline, turn economy, and model-tier routing.

The output tells the user *what's wrong, how risky it is, and what to do* — split
into safe vs sign-off-required actions. It does **not** apply fixes.

---

## Operating Constraints — READ BEFORE RUNNING

These are hard gates. They override any efficiency goal.

1. **Read-only pass.** Inspect and report only. Do not edit config, delete
   worktrees, change models, or modify the memory file during the audit. Fixes are
   a *separate* pass the human authorises.
2. **Court-matter data — HARD STOP.** Never read, index, move, summarise, or
   transmit any Family Court / legal-matter data during the audit. If any audit
   step would touch a path or store containing court data, **stop that step and
   report it as a blocked check** — do not work around it.
3. **Sign-off-required (never auto, even in a later pass):** anything touching
   the global memory file (affects every future run), model-tier or spend changes,
   deleting worktrees or data, or anything touching money, legal, or another person.
4. **Untrusted-until-inspected.** Do not execute third-party tools/skills you
   haven't verified as part of this audit. Inspect their manifest first; report,
   don't run.
5. **Evidence, not assertion.** Every finding cites concrete evidence (a path, a
   command output, a line count, a metric). "Looks fine" is not a finding.

If any constraint conflicts with completing a check, the constraint wins and the
check is marked **BLOCKED** with the reason.

---

## Procedure

Run in order. Do not skip to remediation.

1. **Gather inputs (read-only).** Collect the inspection targets in the table
   below. Where a metric isn't available, mark the check **NO-DATA**, don't guess.
2. **Run Part A**, then **Part B**, then **Part C**. Score each check: **Pass /
   Drift / Gap / Blocked / No-data.**
3. **Assign a per-finding risk rating** and an **overall rating** (see Risk
   Rating).
4. **Emit the report** using the Output Template. Then **STOP** and await the
   human on every sign-off-required item.

### Inspection targets

| Target | How to inspect (read-only) | Feeds |
|---|---|---|
| Config/dotfiles repo | `git -C <repo> status --porcelain`; confirm rebuild path exists | A1, A2 |
| Memory file(s) | Resolve every harness memory path (`CLAUDE.md`, `AGENTS.md`, codex, etc.); compare inode/target; `wc -l` | A3, B3 |
| Skill inventory | List skills dir; check for broken symlinks, duplicates, dead skills | A6, B4 |
| Worktree/herdr state | `treehouse status` / herdr session list; flag stale or orphaned trees | A5, B7 |
| Harness config | Confirm first-mate isn't hard-wired to one harness | A4 |
| Model/context telemetry | Status-line data: model per task, context-window % used per session | B2, B3 |
| Recent session token usage | Per-session/task token counts if logged | B1, B2 |
| Tool-call transport | Which ops go via MCP vs CLI; volume of each | B5 |
| Loop caps | Presence of token/iteration/stop caps on long/overnight runs | B6 |
| Prompt-cache economics | `data/cache-meter.sh` over the live transcript; dedup by requestId | C1, C2 |
| Dispatch profile | `config/crew-dispatch.json` rules vs what routine work actually ran on | C5 |

---

## Part A — System Health

| # | Check | Pass looks like | Drift / Gap signal |
|---|---|---|---|
| A1 | **Reproducible from zero** | One documented command rebuilds first-mate's env on a clean machine. | Install steps live only in memory; no rebuild path. |
| A2 | **Source of truth clean** | Config repo committed and pushed; `git status` clean. | Uncommitted local edits; stale repo. |
| A3 | **Single memory file, distributed** | Every harness memory path resolves to **one** file. | Divergent per-harness rules; agents disagree on conventions. |
| A4 | **Agent-agnostic** | first-mate could swap harnesses without a rebuild. | Hard-coupled to one tool. |
| A5 | **Worktree hygiene** | treehouse/herdr trees all live/accounted-for. | Orphaned or stale trees; collisions in a shared tree. |
| A6 | **Skill inventory integrity** | Skills load, no broken symlinks, no duplicates. | Dead/duplicate skills; broken links. |

## Part B — Operational Efficiency

| # | Check | Pass looks like | Drift / Gap signal |
|---|---|---|---|
| B1 | **Output token economy** | Agents emit lean structured output, not verbose dumps (AXI: structured ≈ 40% of JSON cost). | Bloated JSON/verbose output on high-frequency calls. |
| B2 | **Model tiering** | Cheap/routine tasks on cheap models; premium model reserved for hard reasoning. | Premium model doing work a smaller model handles → spend leakage. |
| B3 | **Context-window discipline** | Memory file lean (loads every session); context % kept low; compaction/handoff used. | Bloated memory file; context near-full from re-reading; no handoff notes. |
| B4 | **Skill progressive-disclosure** | Conditionally-useful detail lives in skills that load on demand, not in always-on memory. | Everything crammed into the always-loaded layer. |
| B5 | **Tool-transport cost** | High-traffic ops use CLI where a CLI exists (MCP measured ~3× tokens, ~2× latency vs CLI for the same op). | Heavy operations routed through MCP with a cheaper CLI equivalent available. |
| B6 | **Loop economics** | Long/overnight runs have token/iteration/stop caps. | Uncapped loops; runaway risk. |
| B7 | **Parallelism utilisation** | Parallelisable work uses isolated worktrees; serial work stays serial. | Serial execution of parallelisable work, *or* over-spawning agents (cognitive + token surface). |
| B8 | **Redundant work** | Context/plan/validation results reused across steps. | Re-reading the same files, re-planning, re-validating unchanged work. |

## Part C — Operational Efficiency (In-Session)

Part C audits the conductor's own conduct this session, from logged data rather than impression.
Where Part B inspects the static setup, Part C inspects what first-mate actually did.
It is read-only: it runs the meter and reads logs, and never applies a fix.

| # | Check | Pass looks like | Drift / Gap signal |
|---|---|---|---|
| C1 | **Cache health (measured)** | Run `data/cache-meter.sh` over the live transcript; hit-rate held high (roughly >= 93%) and cache-write a modest share of spend. | Write-share climbing, or one or more >50k zero-read bust turns present. |
| C2 | **Idle-TTL busts (root-cause aware)** | No avoidable bust turns; any bust is an unavoidable cold-start session opener. | Large cache-write bust turns following an idle gap > 5 minutes. |
| C3 | **Delegation discipline** | Verbose reads, bulk file/upload reviews, and doc-digs run in subagents (a separate context window). | Large one-shot reads or terminal dumps landing in the main context. |
| C4 | **Turn economy** | No re-reads of files already in context; edits batched; no wasted-path turns. | Repeated re-reads, trickled one-at-a-time edits, or turns spent on a path later abandoned. |
| C5 | **Model tiering (in-session)** | Routine and mechanical crew and scout work hits the Haiku rule in `config/crew-dispatch.json`; the premium tier is reserved for hard reasoning. | A premium model running rote work a cheaper tier handles. |
| C6 | **Anti-anchoring gate** | Every efficiency saving in the report is computed from logged token counts or explicitly deferred to forward-measurement. | An inline guessed dollar or percent saving that was reasoned rather than computed. |

### Part C measurement notes

`data/cache-meter.sh` is the sensor for C1 and C2; read its header for invocation and what it reports, and do not restate its mechanics here.

Two facts are load-bearing for a correct Part C reading, both learned from a verified closed-loop tune (see `data/learnings.md`, dated entry on prompt-cache economics):

- **Dedup by requestId first.** The transcript logs each assistant turn twice (a streaming partial plus a final record), so a raw count double-counts writes and busts. Dedup by `requestId` before trusting any figure, or C1 and C2 over-report.
- **The big-bust root cause is idle-TTL expiry, not prefix churn.** The 5-minute prompt-cache TTL lapses during walk-away or watcher idle waits, and the next turn re-writes the whole accumulated prefix at the write rate. Correlate busts with preceding idle gaps (C2), and do not misattribute them to the session-start digest or to memory-file size. A stable cached memory file is read at roughly 10% of its size, so trimming it buys almost nothing and is sign-off, all-agent-risk work; the meter, not the line count, decides whether any trim is worth proposing.

**C6 is a hard gate on the report itself.** A predicted number pulled from reasoning rather than from the logs is contaminated and must not appear anywhere in the output. Compute it from logged tokens, or mark it "defer to forward-measurement".

---

## Risk Rating

Rate each finding and the overall audit — mirrors the no-mistakes convention so the
user knows how hard to review:

- **GREEN** — ergonomic/efficiency only; touches nothing legal/money/people; safe to
  action in a later pass with a glance.
- **AMBER** — affects cost, all-agent behaviour (memory file), or reproducibility;
  needs deliberate review before any change.
- **RED** — touches court data, data deletion, money, or another person; or a Part A
  Gap that means the stack can't be trusted to rebuild. Human decides; first-mate
  proposes nothing beyond flagging.

**Overall = the highest single rating present.** Any RED → overall RED.

Part C findings flow through this same rating and the same remediation gating.
A Part C remediation that touches the memory file, a model or spend change, data deletion, or a court path is SIGN-OFF: yes, exactly as elsewhere.
A purely behavioural Part C fix that first-mate can adopt in its own conduct, such as delegating verbose reads or batching edits, is GREEN and needs no sign-off.

---

## Output Template (first-mate must emit exactly this shape)

```
# First-Mate Self-Audit — <D MMM YYYY>
Scope: <what was inspected>   Overall risk: <GREEN|AMBER|RED>
Counts: __ Pass / __ Drift / __ Gap / __ Blocked / __ No-data

## Part A — System Health
| Check | Status | Evidence | Risk |
| A1 .. A6 | ... | <path/command/metric> | G/A/R |

## Part B — Operational Efficiency
| Check | Status | Evidence | Risk |
| B1 .. B8 | ... | <metric/count> | G/A/R |

## Part C — Operational Efficiency (In-Session)
| Check | Status | Evidence | Risk |
| C1 .. C6 | ... | <computed metric from logs, or NO-DATA> | G/A/R |

## Remediation (Now / Next / Later)
NOW  (1 domino): <single highest-leverage action>  [SIGN-OFF: yes/no]
NEXT: <2-3 items>                                   [SIGN-OFF labelled each]
LATER: <backlog>                                    [SIGN-OFF labelled each]

## Blocked / court-firewall notes
<any check stopped by the hard-stop or a sign-off gate>

## Resumable recap (2 lines)
<state of the stack in 2 lines>
Next action: <one action>
```

**Remediation labelling rule:** every proposed action carries `[SIGN-OFF: yes]`
unless it is GREEN and touches nothing in the memory file, models, spend, data
deletion, or court paths. When in doubt → `[SIGN-OFF: yes]`.

---

## Cadence & tripwires

Run **quarterly**, and immediately if any tripwire fires:

- An agent repeats a mistake there's already a rule against → A3 (distribution) broken.
- Token spend surprises you → B1/B2/B5, and C1/C2 for the in-session cause.
- A config change vanished overnight → A2 broken.
- A run didn't stop when it should have → B6.
- You hesitate to wipe and rebuild the machine → A1; that hesitation *is* the finding.
- The status line shows a `BUST` marker or a run of large cache-write turns → C1/C2.
- Routine crew work ran on the premium tier → C5.

Diff this run's Pass/Drift/Gap counts against the last to quantify drift over time.
