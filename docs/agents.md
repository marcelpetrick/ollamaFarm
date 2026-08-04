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
6. **Conventional Commits, atomic, with a body that explains *why*.** A commit that
   changes behaviour should say what was measured to justify it.

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

## Versioning

Semantic versioning, patch-per-commit.

- `VERSION="0.0.N"` near the top of `ollamaFarm.sh` is the single source of truth.
- Increment the patch on **every** commit that touches the tool.
- The version renders in the header (`┌─ Ollama farm 0.0.9 ──…──┐`), so a screenshot
  identifies its build.
- Tags are `v0.0.N`.

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
run `ollama serve` locally and use `-H 127.0.0.1`. To see the eviction detector
fire, load two models that cannot both fit in VRAM and watch the event log.
