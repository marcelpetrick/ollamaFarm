# agents.md

Guidance for AI coding agents working in this repository. Humans may find it useful
too, but it exists because agents need the constraints stated explicitly.

## What this project is

One Bash script, `ollamaFarm.sh`, that polls the Ollama HTTP API on a few hosts and
renders a terminal dashboard. Plus `localPipeline.sh`, which checks it. That is the
whole repository. Resist the urge to add a package manifest, a build system, a test
framework, or a second language.

## Hard rules

1. **Run `./localPipeline.sh` before claiming anything works.** All ten stages, and
   read the summary. `shellcheck -S warning` must stay clean. A green `bash -n` is
   not evidence that the tool renders.
2. **Never fabricate a measurement.** Every number in the README and in the script's
   comments was measured on real hardware. If you cannot measure it, say so, or leave
   it out. The one invented frame in the README is explicitly labelled as fabricated,
   and it must stay labelled.
3. **The servers are shared.** `192.168.100.67` belongs to a colleague. Do not
   delete models, do not create models, do not raise the poll rate to prove a point.
   The monitor is read-only against `/api/version`, `/api/ps` and `/api/show`; keep
   it that way.
4. **Do not add features that cannot work.** An `--ssh` flag for GPU telemetry was
   removed for exactly this reason: it was documented, inert, and dependent on access
   that never arrived. Absent beats advertised-but-broken.
5. **Bump the patch version in every commit.** `VERSION` near the top of
   `ollamaFarm.sh`, and it is shown in the header. See "Versioning" below.
6. **Conventional Commits, atomic, with a body that explains *why*.** See
   "Commit style" below — it is the rule most often got wrong here.

## Traps specific to this codebase

These have all been hit and fixed once. Do not reintroduce them.

- **`$(render_host …)` runs in a subshell.** The eviction detector keeps state in
  `PREV_MODELS` / `PREV_TTL` / `EVENTS`, and the `/api/show` results are cached in
  `SHOW_CACHE`. Capturing the renderer with command substitution silently discards
  all of it, and the detector can never fire. Frames are assembled in-process via
  `emit()` (`printf -v`). Keep it that way.
- **`emit` is not a drop-in for `printf`.** It writes to `$OUT`, not stdout. A
  blanket `printf` → `emit` rewrite once broke the data path
  (`used=$(printf '%s' "$ps" | jq …)` became `emit`, so `jq` got empty input and
  every host rendered as idle while models were plainly resident).
- **`${#var}` counts escape bytes.** Anything whose *visible* width matters — the
  header rule, the pause badge, the status line — needs a plain twin without colour
  codes for measuring.
- **Every rendered line needs `\e[K`,** or a short line leaves the tail of the longer
  line that occupied that row in the previous frame. Frames also must not exceed the
  terminal height, or the display scrolls and `\e[H` stops aligning.
- **`grep` here is `ugrep`,** which parses a leading `-` in a pattern as an option
  even with `-F`. Use bash string containment or `awk` when matching flags.
- **Do not edit a running shell script.** Bash reads scripts incrementally; changing
  byte offsets under a running interpreter can drop it mid-statement.
- **Eviction is not atomic.** A model unloads, and its replacement becomes resident
  seconds to a minute later. Detection correlates across polls within
  `SUSPECT_WINDOW`; a naive "vanished while something appeared" test never matches.

## Commit style

**Conventional Commits**, one logical change per commit, with a body that explains
*why* rather than restating the diff.

```
<type>[optional scope][!]: <subject in the imperative, lower case, no full stop>

<body: what was wrong, what was measured, why this fix and not another>

[BREAKING CHANGE: <what breaks, for users>]
```

Types used in this repository:

| type | for |
|---|---|
| `feat` | new user-visible capability |
| `fix` | a defect in behaviour |
| `refactor` | restructuring with no behaviour change (`refactor!` if something is removed) |
| `perf` | a measured speed or resource improvement |
| `style` | appearance only — layout, colour, alignment |
| `docs` | README, this file, comments |
| `build` | `localPipeline.sh`, packaging, tooling |
| `chore` | licence, `.gitignore`, housekeeping |

### Atomic means one reason to change

Do not bundle a fix with the documentation of a *different* fix. Do bundle a code
change with the doc, README frame, and pipeline check that belong to it — those are
the same logical change, and splitting them leaves the repository briefly
self-contradictory.

If work turns out to be two things, commit it as two.

### The body is the point

This project's value is in its measurements, so a commit that changes behaviour
should say what was observed. Good bodies here have looked like:

- *"Measured on .67: prompts of ~66k and ~132k tokens both report exactly 30002
  processed tokens"* — the evidence for the change.
- *"Verified by sabotage: breaking the interval ladder trips stage 6, chmod -x trips
  stage 4"* — evidence the check actually works, not just that it passed once.
- *"An earlier version shipped an --ssh flag that was permanently inert"* — why the
  change is a removal rather than a fix.

State what you did **not** verify, too. "Untested against Ollama 0.30.x" is worth a
line; a silent gap is not.

### Do not

- Write `fix: bug` / `chore: update` / `docs: improve` — say which bug, what update.
- Claim a verification you did not run. If `localPipeline.sh` was not run, do not
  write that it passes.
- Amend or rebase published history without being asked. The version-per-commit
  history was rewritten once, deliberately, with a backup branch and a diff proving
  the trees were identical apart from the intended change.
- Commit generated artefacts (`~/.config/ollamafarm/*`, pipeline logs, temp files).

## Versioning

Semantic versioning, patch-per-commit.

- `VERSION="0.0.N"` near the top of `ollamaFarm.sh` is the single source of truth.
- Increment the patch on **every** commit. A docs-only commit still bumps it, so the
  version identifies a repository state rather than only a code state. Where an image
  in the docs shows an older version, caption it with the version it was captured
  from instead of silently letting it drift.
- The version renders in the header (`┌─ Ollama farm 0.0.N ──…──┐`), so a screenshot
  identifies its build, and `--version` prints it.
- **Do not create git tags.** They were used briefly and removed: the version lives
  in the script, and a second copy in a ref is one more thing that can disagree with
  it. `VERSION` is the single marker.

While the major version is 0 the interface is not stable; a breaking change is
marked with `!` in the commit type and a `BREAKING CHANGE:` footer, but does not
force a major bump yet.

## Style

- Bash with `set -uo pipefail`. `curl`, `jq`, `awk` only — no new dependencies
  without a strong reason, and check for them at startup if you add one.
- Comments explain **why**, especially where the code looks odd. Most of the odd
  code here is odd because of a measured constraint; say which one.
- Colour encodes state, never decoration: green healthy, red costing you throughput
  now, yellow about to change. Honour `NO_COLOR` and non-tty output.
- Prefer honest gaps over guessed values. Unknown usable VRAM prints `?` and draws
  no bar rather than inventing a total.

## Getting a real test environment

Without an Ollama host, stages 1–9 of the pipeline still run; stage 10 skips. To
exercise the interesting paths you need a reachable server: point `-H` at one, or
run `ollama serve` locally and use `-H 127.0.0.1`.

**A loopback server is never auto-discovered**, and this is confirmed rather than
assumed: discovery only scans `/24`s derived from hosts it already knows, so with LAN
seeds it never probes `127.0.0.0/8`. Measured — a server on `127.0.0.1` was missed by
`-D`, and found immediately when seeded with `-H 127.0.0.1` (which makes the scan
range `127.0.0.1-254`). Whether an address is public or private is irrelevant; only
its numeric range matters.

To see the eviction detector fire, load two models that cannot both fit in VRAM and
watch the event log. A throwaway HTTP server answering `/api/version` and `/api/ps`
is enough to exercise rendering without any real model.
