# LinkedIn notes

Raw material for an article about `ollamaFarm`. Ten points, ordered so they can be read
straight down as a narrative: the joke, the problem, the build, the honesty.

Every figure below is measured and already carried in [README.md](README.md) — nothing
here is rounded up for effect. If a number is quoted in the article, quote its caveat
too (see "Do not overclaim").

---

## Ten points

1. **The name is the whole joke, and the joke is the architecture.** Ollama runs
   llamas 🦙. One llama is a pet. Several llamas on several machines is a **farm** — so
   the tool is a farmer's view of the herd: who is in which barn, what each animal
   weighs, which one is about to be turned out to make room for a bigger one. Every
   term in the UI survives the metaphor, which is usually a sign the metaphor was the
   right one.

2. **Before it existed, checking the farm meant SSH-ing into each box and running
   `ollama ps`.** Three shells, three snapshots, taken at three different moments —
   and the interesting failures happen *between* snapshots. `ollamaFarm` is `htop`/`btop`
   for LLM boxes: every host, every resident model, one screen, 1 Hz. One Bash file,
   `curl` + `jq` + `awk`, no daemon, no agent installed on the servers, no account
   needed on machines you are watching.

3. **It finds the herd by itself.** Press `d` (or start with `-D`) and it derives the
   `/24` from the hosts it already knows and probes `/api/version` on `.1`–`.254`,
   **64 at a time** with a 0.6 s timeout — both servers found well inside a single
   refresh interval. Two limits are deliberate: it only scans subnets it already has a
   foot in (a monitor should not blind-scan arbitrary ranges unasked), and a
   loopback-only server is therefore never auto-discovered. That last one is confirmed
   by experiment, not assumed.

4. **The switches are the product, not the garnish.** `+`/`-` steps a refresh ladder
   `0.25 0.5 1 2 3 5 10 30` s; `p` pauses (and a paused frame genuinely polls nothing);
   `v m w e` toggle VRAM bars, per-model detail, config warnings, event log; `d`
   re-discovers; `t` cycles themes; `s` re-scans idle hosts; `h` is the help overlay.
   All of it persists to `~/.config/ollamafarm/config`, so the rate you chose at 2 a.m.
   is still there tomorrow.

5. **`+` makes it *slower*, and that is the correct direction.** `+` raises the interval
   *number*, exactly like `btop`. It reads wrong for about four seconds and then never
   again — because the muscle memory being served is the one users already have. A
   related small mercy: any section you switch off is named in the header
   (`hidden: models:off(m)`), so a toggle saved months ago can never leave someone
   staring at a screen that merely *looks* broken.

6. **Three colour themes, and colour is a data type here.** `dark` deliberately stays
   8-colour ANSI so it inherits *your* palette and still works over serial, in a VM
   console, under `TERM=linux`. `vivid` is a loud 256-colour look. `light` avoids yellow
   entirely, because yellow on white is unreadable. Colour is assigned **by role, never
   at the call site**: green is healthy, yellow is about to change, red is costing you
   throughput *right now* — in every theme. A theme can repaint a meaning; it cannot
   repurpose one. `NO_COLOR` is honoured.

7. **A VRAM bar needs a denominator, and Ollama does not have one.** Every plausible
   endpoint was probed on a live server: `/api/ps` gives per-model `size` and
   `size_vram` but no totals; `/metrics`, `/api/gpu`, `/api/system`, `/api/health` all
   **404**. Ollama knows the number — it prints it to its own log at boot — and serves
   it nowhere. So the bar had to earn its denominator some other way.

8. **So it asks the hardware instead of the API.** The probe loads a model at escalating
   `num_ctx` and watches for the moment part of it spills into system RAM, then narrows
   in on the boundary. Output looks like `0.0/7.77+ GB` — and **the `+` is
   load-bearing**: it means *at least this much fits*, a measured lower bound, not a
   capacity. When nothing is known it prints `?` and draws **no bar at all**. Refusing
   to invent a plausible number is the single most important design decision in the
   repository.

9. **Probing someone else's GPU is a trust exercise, so it has rules.** The scan touches
   **idle hosts only** — anything resident and the host is skipped *loudly*, naming what
   it would have had to evict. Every test load is followed by an explicit
   `keep_alive: 0` unload. It runs detached, so the dashboard keeps refreshing while
   progress lands in the event log. `--no-auto-scan` opts out entirely. One of the boxes
   belongs to a colleague; evicting their model would cost them ~70 s, and no monitor
   has the right to spend someone else's time to draw a prettier bar.

10. **The real payload: four ways an Ollama box quietly wastes your GPU, none of which
    reports an error anywhere.** **Eviction thrash** — a second model displaces the
    resident one, and the next request pays a **~70 s** reload; visible only by diffing
    across polls, never in a snapshot. **Split placement** — part of the model sits in
    system RAM: **5.3× slower**, same weights, only `num_ctx` changed (29.6 → 5.6 tok/s).
    **No baked `num_ctx`** — capped at **16k** tokens through `/v1/messages`, past which
    `tool_use` blocks simply stop appearing, silently. **`presence_penalty = 1.5`**, a
    vendor default — **~35%** of generation throughput, for nothing (129.5 → 84.4 tok/s).
    The last two are invisible to `ollama ps`. The first is invisible to any snapshot at
    all. That is why this is a monitor and not a script.

---

## Angles, if the article needs a spine

- **"The `+` key and the missing bar."** Both are one-line decisions that took longer to
  settle than the code around them. Good material for a piece about small design calls.
- **"There is no API for that."** The VRAM investigation reads as a detective story:
  every endpoint tried, all 404, and the answer turns out to be *measure it yourself*.
  Written up in full in [docs/vram-discovery.md](docs/vram-discovery.md).
- **"Silent failure is the expensive kind."** Four defaults, no errors, and a measured
  bill for each. Nothing in this list throws.
- **"Read-only, except once, and it says so."** The tool is credential-free monitoring
  with exactly one deliberate exception, documented rather than buried.

## Do not overclaim

- The numbers are **specific to two boxes and the qwen3.5/3.6 family** — a 12.2 GB host
  on Ollama 0.30.6 and a 36.1 GB dual-GPU host on 0.32.5, across 13 model
  configurations. The `~70 s` reload is what *a 33 GB MoE* costs, not a universal
  constant.
- The 16k finding is **version dependent**: 0.32.5 truncates an overflowing prompt to
  `num_ctx/2`, 0.30.6 fills the window normally. A newer Ollama is something to
  re-measure, not something to assume.
- The probed ceiling is a **lower bound on the usable ceiling**, which is itself lower
  than the hardware total `nvidia-smi` reports. Do not write "detects your VRAM".
- GPU temperature, utilisation, fan and power are **not** shown, and that is a
  deliberate limit: they live in `nvidia-smi`, reaching them needs SSH to every host,
  and needing no credentials is exactly what makes this safe to point at a colleague's
  machine. An earlier `--ssh` flag was removed for being permanently inert.
- It cannot tell you whether a model is *generating* — `/api/ps` reports residency, not
  activity. Latency is the proxy, which is why it turns yellow past 400 ms.
- The project was **generated with AI assistance**; the README says so and the article
  should too.
