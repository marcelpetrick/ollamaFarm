# Plan: discovering usable VRAM

Currently `VRAM_TOTAL` is a hardcoded table, and a host that is not in it shows `?`
with no bar. This is the investigation into whether that can be automated, what is
actually possible through the API, and a plan for what to build.

Everything below was probed against live servers, not inferred from documentation.

---

## 1. What the API exposes

Every endpoint on Ollama 0.32.5 that could plausibly carry hardware information:

| endpoint | result |
|---|---|
| `/api/ps` | `size`, `size_vram`, `context_length` **per resident model**. No totals. |
| `/api/version` | version string only |
| `/api/tags` | on-disk models |
| `/api/show` | `parameters`, `model_info`, `template`, `tensors` — model, not machine |
| `/api/status` | exists but undocumented: `{"cloud":{"disabled":false,"source":"none"}}` |
| `/v1/models` | OpenAI-compatible model list |
| `/metrics`, `/api/info`, `/api/health`, `/api/gpu`, `/api/system`, `/debug/vars`, `/debug/pprof` | **404** |

**There is no total-VRAM, free-VRAM, or GPU-count field anywhere in the HTTP API.**
Ollama knows the number — it prints it to its own log at startup — but does not serve
it. Reading the log needs shell access on the host, which this tool deliberately does
not have.

So the honest answer to "is there really no API for this" is: **no, not directly.**
But the API does leak enough to *infer* a usable figure, which is what the rest of
this plan is about.

## 2. Two different numbers, and only one of them matters

- **Hardware total** — what `nvidia-smi` reports. 8192 MiB for an RTX A2000.
  Not obtainable through the API.
- **Usable ceiling** — how much Ollama will actually put on the GPU before it starts
  splitting to system RAM. Always lower: Ollama keeps a reserve, offloads whole
  layers only, and shares the card with whatever else is on the desktop.

For a monitor whose job is warning about splits and evictions, the **usable ceiling is
the more useful number**, and it is the one that can be observed. A bar drawn against
the hardware total would show headroom that does not exist.

## 3. Measured behaviour

### An absurd `num_ctx` is clamped to the model's architecture, not to VRAM

Requesting `num_ctx: 100000000` on a 4B model did **not** error and did **not** clamp
to what fits. It clamped to 262144 — the model's trained maximum — and then split:

```
context_length 262144   size 13.74 GB   size_vram 6.19 GB   -> split
context_length   8192   size  3.34 GB   size_vram 3.34 GB   -> fully resident
```

So there is no "ask for too much and be told the limit" probe. Ollama does not refuse;
it degrades silently. (This is the same silent-degradation habit behind the `num_ctx`
overflow and 16k-cap findings in the README.)

### A split under-reports capacity, sometimes badly

On the 8192 MiB card, at the moment of splitting Ollama had placed **6.19 GB** on the
GPU. Ground truth from `nvidia-smi` was **8192 MiB ≈ 8.19 GB**. The split figure
under-reports by roughly a quarter, because of the layer-granularity and reserve
effects above.

Worse, a split figure can be **lower than a residency already observed to succeed**.
From the 36 GB host:

| observation | `size_vram` | placement |
|---|---|---|
| `35b-a3b-q4_K_M-ctx256k` | **33.09 GB** | fully resident |
| `27b-mtp-q8_0-ctx128k` | 32.07 GB of 36.65 GB | split |

A naive "capacity = `size_vram` at the split" would have concluded 32.07 GB, which is
demonstrably wrong — 33.09 GB had already fitted. **Split events are a soft signal
that capacity is near, not a measurement of it.**

### What is a sound lower bound

The largest total that has been observed **fully resident**:

```
ceiling ≥ max over time of ( Σ size_vram , when nothing is split )
```

This is a hard lower bound — it is a configuration that demonstrably worked. It costs
nothing extra: `/api/ps` is already polled every frame.

## 4. Candidate paths

| path | cost | accuracy | invasive? |
|---|---|---|---|
| **A. Passive learning** — track the largest fully-resident total per host | zero extra requests | lower bound, tightens over time | no |
| **B. Split-event hint** — note `size_vram` when a split occurs | zero | unreliable (see above) | no |
| **C. Active probe** — load a model at escalating `num_ctx` until it splits | minutes; evicts whatever is resident; ~70 s reload afterwards | good, still a lower bound | **yes, badly** |
| **D. Config override** — user states the figure per host | zero | exact, if the user knows it | no |
| **E. `nvidia-smi` over SSH** | needs credentials on every host | exact hardware total | rejected — removed in 0.0.9 |

Path C is the method that produced the existing `36.1` and `12.2` figures, run by hand
against those two hosts. It works, but on a shared server it evicts a colleague's model
and costs them a 70-second reload, which is not something a monitor may do on its own.

## 5. The plan

**Build A and D. Offer C only behind an explicit flag. Never do B alone.**

### Phase 1 — passive learning (default, zero cost)

1. Track per host, across polls: `observed_max` = largest `Σ size_vram` seen with
   nothing split.
2. Persist to `$XDG_CONFIG_HOME/ollamafarm/vram` as `host=bytes,source=observed`.
3. Display:
   - host in `VRAM_TOTAL` or overridden in config → bar as today, exact label
   - otherwise, if `observed_max` exists → `12.4+ GB` with a **`+`** suffix and a bar
     drawn against `observed_max`, so it reads as "at least this much"
   - otherwise → `?` and no bar, as today
4. The `+` is load-bearing: it distinguishes a lower bound from a known total. A bar
   that silently means two different things is worse than no bar.

### Phase 2 — config override (zero cost)

Accept `vram.<host>=<GB>` in the config file, and a `--vram HOST=GB` flag, so a user
who knows the figure can state it without editing the script. This also lets someone
correct a bad passive estimate.

### Phase 3 — opt-in active probe (`--probe-vram HOST`)

Only when explicitly asked, never from the TUI, never automatically:

1. Refuse unless the host is idle (`/api/ps` empty). **Do not evict anyone's model** —
   print what is resident and exit non-zero instead.
2. Pick the smallest model on that host, to minimise load time.
3. Binary-search `num_ctx` between the model's minimum and its architectural maximum,
   loading with `keep_alive: 0` each time, until the largest fully-resident
   `size_vram` is found.
4. Record it as `source=probed` and unload.
5. Print, before starting: what it will load, how long it may take, and that the host
   must be idle. Require `--yes` to skip the confirmation.

Even then the result is a lower bound, and must be labelled as one.

### What will not be built

- No automatic probing on startup or on the `d` key.
- No inference of capacity from a split event alone.
- No hardware-total reporting, because the API cannot supply it and guessing it would
  put fictional headroom on the bar.

## 6. Risks

- **Passive estimates start low and only grow.** A freshly started monitor watching an
  idle host learns nothing. That is honest but can look unhelpful; the `+` suffix and
  the `?` fallback have to make the state obvious.
- **A stale learned value can mislead** if a GPU is removed or another process takes
  VRAM. Store a timestamp with it, and prefer an explicit override when present.
- **Sharing a card with a desktop session** makes the usable ceiling genuinely
  variable. This is a real property of the machine, not an error in measurement, and
  the label should not pretend otherwise.
