# Architecture

A [C4](https://c4model.com/) walk through `ollamaFarm.sh`, from the outside in. The
whole tool is two shell scripts and a config directory, so the interesting structure is
not in the file layout — it is in **which process talks to which server, and which of
those conversations are allowed to write**.

That distinction is the spine of the design: the refresh loop is strictly read-only and
needs no credentials, and exactly one feature departs from that, under rules spelled out
at every level below.

---

## Level 1 — System context

```mermaid
flowchart LR
  op["<b>Operator</b><br/>watches a small farm of<br/>GPU boxes from a terminal"]

  subgraph sys [" "]
    farm["<b>ollamaFarm.sh</b><br/>btop-style monitor.<br/>Shows residency, spots<br/>evictions and splits,<br/>measures VRAM ceilings"]
  end

  ollama["<b>Ollama hosts</b><br/>HTTP API on :11434<br/>one per GPU box"]
  store[("<b>Config directory</b><br/>$XDG_CONFIG_HOME/ollamafarm")]

  op -->|"keystrokes: refresh rate,<br/>toggles, d, s, q"| farm
  farm -->|"a repainted frame<br/>every 0.25-30 s"| op
  farm ==>|"<b>READ</b> /api/version /api/ps<br/>/api/tags /api/show"| ollama
  farm -.->|"<b>WRITE</b> /api/generate<br/>ceiling scan only,<br/>idle hosts only"| ollama
  farm <-->|"settings, host list,<br/>learned ceilings"| store

  classDef sysStyle fill:#1168bd,stroke:#0b4884,color:#fff
  classDef extStyle fill:#999,stroke:#6b6b6b,color:#fff
  class farm sysStyle
  class ollama,store extStyle
  style sys fill:none,stroke:none
```

The dotted edge is the entire trust surface. Everything else only reads.

**Deliberately outside the system:** GPU temperature, utilisation, fan and power. They
live in `nvidia-smi`, reaching them would need SSH to every host, and needing no
credentials is what makes this safe to point at a colleague's machine. An earlier
`--ssh` flag was removed for being permanently inert.

---

## Level 2 — Containers

One file, but three distinct runtime roles, chosen by flag. They coordinate only through
files in the config directory — there is no socket and no shared memory.

```mermaid
flowchart TB
  op(["Operator"])

  subgraph proc ["ollamaFarm.sh — three runtime roles"]
    tui["<b>TUI process</b><br/>default invocation<br/><i>the refresh loop, read-only</i>"]
    worker["<b>Detached scan worker</b><br/>--probe-worker<br/><i>started by 's' or auto-scan</i>"]
    cli["<b>Foreground scan</b><br/>--probe-vram<br/><i>scriptable, no TUI</i>"]
  end

  subgraph files ["Config directory — the only channel between roles"]
    cfg[("config<br/><i>interval, toggles,<br/>history length, theme</i>")]
    hosts[("hosts<br/><i>cached discovery</i>")]
    vram[("vram<br/><i>host, GB, source, epoch</i>")]
    plog[("probe.log<br/><i>worker progress, append-only</i>")]
    plock[("probe.lock<br/><i>pid of the running scan</i>")]
  end

  ollama["<b>Ollama hosts</b> :11434"]

  op --> tui
  op --> cli
  tui -->|"setsid nohup, so the<br/>display keeps refreshing"| worker

  tui <--> cfg
  tui <--> hosts
  tui <--> vram
  worker --> vram
  cli --> vram
  worker -->|writes progress| plog
  tui -->|"tails from a byte offset,<br/>folds into the event log"| plog
  tui <--> plock
  worker --> plock
  cli <--> plock

  tui ==>|read-only polling| ollama
  worker -.->|"load / unload<br/>idle hosts only"| ollama
  cli -.->|"load / unload<br/>idle hosts only"| ollama

  classDef roleStyle fill:#1168bd,stroke:#0b4884,color:#fff
  classDef fileStyle fill:#f5f0e1,stroke:#b8a97a,color:#333
  class tui,worker,cli roleStyle
  class cfg,hosts,vram,plog,plock fileStyle
```

Two details in that picture are load-bearing:

- **`probe.log` is read from a byte offset, not from the start.** Replaying it from zero
  made a previous session's scan reappear as if live, and re-adopted its `RESULT` lines,
  resurrecting a ceiling the user had just deleted. The offset is initialised to the
  log's current end at startup, so only output produced after this process started is
  ever read.
- **`probe.lock` holds a pid, not a flag.** A crashed scan leaves the file behind, so
  liveness is tested with `kill -0` rather than existence, and a stale lock self-heals.
  All three roles take it, so a foreground `--probe-vram` cannot be run alongside a TUI
  scan of the same GPU.

---

## Level 3 — Components inside the TUI process

```mermaid
flowchart TB
  subgraph loop ["Refresh loop — one pass per interval"]
    geom["<b>Geometry + header</b><br/>re-reads stty size every frame;<br/>the rule is cut to the status line,<br/>the frame clipped to the terminal"]
    render["<b>render_host</b><br/>version, latency, bar,<br/>per-model detail"]
    diff["<b>Eviction detector</b><br/>diffs resident model sets<br/>between consecutive polls"]
    ceil["<b>Ceiling resolver</b><br/>picks the denominator<br/>and how to label it"]
    warn["<b>Config warnings</b><br/>presence_penalty, missing num_ctx<br/><i>/api/show, cached per host+model</i>"]
    events["<b>Event ring buffer</b><br/>last 5 / 10 / 20 / 50 state changes"]
    paint["<b>Frame painter</b><br/>erase-to-EOL per line,<br/>repaint from \\e[H"]
  end

  keys["<b>Key handler</b><br/>read -t doubles as the sleep,<br/>so keys stay responsive"]
  disc["<b>Discovery</b><br/>/api/version across the /24,<br/>64 in parallel"]
  probe["<b>Scan launcher</b><br/>idle-host and lock checks,<br/>then detaches a worker"]

  geom --> render --> diff --> ceil --> warn --> events --> paint
  paint --> keys
  keys -->|"d"| disc
  keys -->|"s"| probe
  keys -->|"+ - v m w e l p t h"| geom
  diff --> events
  disc --> events
  probe --> events

  classDef comp fill:#4a89c7,stroke:#2d5a8a,color:#fff
  classDef act fill:#7aa9d4,stroke:#2d5a8a,color:#fff
  class geom,render,diff,ceil,warn,events,paint comp
  class keys,disc,probe act
```

`render_host` runs **in the current shell**, never in `$(...)`. It mutates the eviction
detector's state and the `/api/show` cache; a subshell would silently discard both, so
the detector would never fire and the cache would re-query a shared server every poll.
Frames are assembled into a string with `printf -v` for the same reason.

### The ceiling resolver

The denominator of the VRAM bar comes from three sources. Every one of them is a
footprint that was demonstrated to fit, so the largest wins and every figure carries a
`+`. How the figure is labelled is the most carefully guarded decision in the tool.

```mermaid
flowchart TB
  floor["<b>VRAM_FLOOR</b><br/><i>demonstrated by hand</i>"]
  probed["<b>probed</b><br/><i>the scan's best fit</i>"]
  learned["<b>learned</b><br/><i>largest fully-resident<br/>total observed</i>"]
  q{"any of them<br/>known?"}
  lower["<b>the largest</b> — 40.4+ GB<br/><i>a LOWER BOUND.<br/>The '+' is load-bearing</i>"]
  none["<b>unknown</b> — 0.0 GB/?<br/><i>no bar at all, rather<br/>than a guessed one</i>"]

  floor --> q
  probed --> q
  learned --> q
  q -->|yes| lower
  q -->|no| none

  classDef src fill:#4a89c7,stroke:#2d5a8a,color:#fff
  classDef warnc fill:#b8860b,stroke:#7a5a08,color:#fff
  classDef nonec fill:#777,stroke:#4a4a4a,color:#fff
  class floor,probed,learned src
  class lower warnc
  class none nonec
```

A bar that silently meant either "this is the capacity" or "it is at least this much"
would be worse than no bar.

**A scan does not escape the `+`.** An out-of-memory refusal looks like the upper bound
that would justify dropping it, and briefly was treated as one. It is not: a refusal
bounds the model being loaded, not the machine. On the dual-GPU host,
`qwen3.6:27b-q8_0` reaches 40.47 GB and `qwen3.6:27b-mtp-q8_0-ctx60k` stops at
34.69 GB — same box, same day. Layers divide unevenly across two cards, so one fills
while the other still has room. Full reasoning in
[vram-discovery.md](vram-discovery.md).

---

## Dynamic view — a ceiling scan

The one flow that writes to a server, and therefore the one with rules at every step.

```mermaid
sequenceDiagram
    autonumber
    participant U as Operator
    participant T as TUI process
    participant W as Detached worker
    participant H as Ollama host
    participant F as config files

    U->>T: press "s"
    T->>F: probe.lock — another scan live?
    Note over T,F: refuse rather than stack two scans
    T->>W: setsid nohup --probe-worker
    T-->>U: display keeps refreshing throughout

    W->>H: GET /api/ps
    alt anything resident
        W->>F: log "SKIP — not idle, holding: <model>"
        Note over W,H: never evict — that would cost<br/>the owner a ~70 s reload
    else idle
        W->>H: GET /api/tags — largest model first
        loop until one fits, max 12 rejections
            W->>H: POST /api/generate, num_gpu 999, ctx 2048
            H-->>W: cudaMalloc OOM → too big, step down
        end
        loop binary search, max 7 loads
            W->>H: POST /api/generate, num_gpu 999, ctx N
            alt fits
                H-->>W: size_vram — raise the floor
            else refused
                H-->>W: cudaMalloc OOM — lower the lid
            end
            W->>H: POST /api/generate, keep_alive 0
        end
        W->>F: RESULT host gb probed
    end
    W->>F: release probe.lock
    T->>F: tail probe.log from its offset
    T-->>U: progress and result in the event log
```

Steps 1-4 are the safety envelope; the two loops are the measurement. `keep_alive: 0`
after **every** test load is what keeps the host as idle as it was found.

### Why `num_gpu: 999`

Left to itself Ollama picks the layer count from its own pre-flight estimate, which
deliberately keeps a reserve and can only move whole layers — so watching for the moment
a model splits measures *Ollama's caution, not the GPU*. Pinning the layer count takes
the estimate out of the loop and lets the CUDA allocator answer directly, which reaches
far closer to the real edge of the card.

On the dual-GPU host here that was the difference between a reported 36.1 GB and a
demonstrated 40.4 GB. It does not make the figure exact — see the note under the ceiling
resolver above. Measurements in [vram-discovery.md](vram-discovery.md).

---

## Quality gate

`localPipeline.sh` is the same entry point CI runs, so a green local run means a green
build. Ten stages: tooling, `bash -n`, shellcheck, exec bits, documentation,
**doc/code agreement**, help and argument handling, config robustness, an offline render
smoke test, and an optional live one.

The doc/code agreement stage is the unusual one — it fails the build when the README
documents a flag the parser does not have, when the interval ladder in the prose has
drifted from the array, or when `VERSION` disagrees with `--version`. It has caught real
drift, which is why it is mandatory rather than a lint.
