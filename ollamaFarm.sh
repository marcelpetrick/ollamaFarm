#!/usr/bin/env bash
#
# ollamaFarm.sh — live view of the Ollama servers on the local network.
#
# Copyright (C) 2026 Marcel Petrick <mail@marcelpetrick.it>
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
# PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>.
#
# A btop-style monitor for a small farm of Ollama hosts. Beyond "what is loaded",
# it watches for the four failure modes that this hardware actually suffers from,
# every one of which is silent through the API (see "Where the numbers come from" in README.md):
#
#   1. EVICTION THRASH — a second model displaces the resident one. On the 36 GB
#      box the 33 GB MoE plus anything else does not fit, so any second model
#      unloads it and the next real request pays a ~70 s reload. Invisible in a
#      snapshot; only a diff between polls reveals it.
#   2. SPLIT PLACEMENT — size_vram < size means part of the model sits in system
#      RAM. Measured cost: 5.3x throughput, with no error reported anywhere.
#   3. MISSING BAKED num_ctx — a model whose Modelfile leaves num_ctx unset is
#      capped at 16384 tokens through /v1/messages (which has no num_ctx knob),
#      and tool calling stops entirely past that point without an error.
#   4. presence_penalty != 0 — the qwen vendor default of 1.5 costs ~35% of
#      generation throughput for nothing.
#
# Keys (btop-style), active while running:
#   -  /  +    faster / slower refresh      p   pause (p again to resume)
#   v          VRAM bars on/off             m   per-model detail on/off
#   w          warnings on/off              e   event log on/off
#   l          event history length (5 / 10 / 20 / 50 entries)
#   d          re-run host discovery        t   cycle colour theme
#   s          scan idle hosts for their VRAM ceiling (see docs/vram-discovery.md)
#   h  or  ?   help overlay                 q   quit
#
# Usage:
#   ./ollamaFarm.sh                    # default hosts, 1 s refresh
#   ./ollamaFarm.sh -n 2               # every 2 s
#   ./ollamaFarm.sh -H 192.168.100.67,192.168.100.99
#   ./ollamaFarm.sh -D                 # discover hosts on the /24 at startup
#   ./ollamaFarm.sh --probe-vram       # scan every host now, print, exit
#   ./ollamaFarm.sh --probe-vram HOST  # scan one host now, print, exit
#   ./ollamaFarm.sh --no-auto-scan     # do not bootstrap unknown VRAM ceilings
#   ./ollamaFarm.sh --theme light      # dark (default) | vivid | light | cga | colorblind
#   ./ollamaFarm.sh --no-color         # plain output (also honours NO_COLOR)
#   ./ollamaFarm.sh --version          # print the version and exit
#
# Settings (interval and toggles) persist to $XDG_CONFIG_HOME/ollamafarm/config,
# so the refresh rate you picked is still there next time.
#
# Scope: the monitoring loop reads the Ollama HTTP API and nothing else. GPU
# temperature, utilisation, fan and power are therefore out of scope -- the API does
# not expose them, and reaching nvidia-smi on the hosts would need SSH access this tool
# does not assume it has. The guarded VRAM scan below is the one write-path exception.
#
# On discovery: hosts are found by probing /api/version across the /24, which only
# reads. Usable VRAM is separate: the API has no total-VRAM field anywhere, so the
# figure has to be established by loading a model with every layer pinned to the GPU
# and raising num_ctx until the card refuses. That writes to the server, so automatic
# and manual scans both run against IDLE hosts only and never evict anything;
# --no-auto-scan disables the automatic bootstrap.
# Ceilings already demonstrated by hand are listed in VRAM_FLOOR below; a host with
# neither a table entry nor a scan shows "?" and gets no bar rather than a guessed one.

set -uo pipefail

# Bash 4.0 or newer: associative arrays (declare -A) hold every piece of detector and
# cache state, and "read -t" with a fractional timeout is the frame clock. Bash 3.2, still
# /bin/bash on macOS, has neither. Checked before anything else runs, so the failure is a
# sentence rather than an error from deep inside the first frame.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ollamaFarm.sh needs bash 4.0 or newer; this is bash ${BASH_VERSION:-unknown}" >&2
  exit 1
fi

# Semantic version of this script. Patch is bumped on every commit;
# it is rendered in the header so a screenshot identifies its build.
VERSION="0.0.56"

# Absolute path to this script, for re-launching it as the detached scan worker. "$0" is
# not enough: started as "bash ollamaFarm.sh" it is a bare name, which nohup looks up on
# PATH rather than in the current directory, and the worker silently never ran.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ---------------------------------------------------------------- defaults ----
PORT=11434
DEFAULT_HOSTS="192.168.100.37 192.168.100.67"
HOSTS="$DEFAULT_HOSTS"
DO_DISCOVER=0
PROBE_WORKER=0
PROBE_CLI=0                # --probe-vram: scan in the foreground, print, exit
AUTO_SCAN=1                # bootstrap an unknown ceiling automatically, idle hosts only
WANT_COLOR=auto
# Colour themes, cycled by the "t" key in this order. "dark" is plain ANSI so it
# works on any terminal; the others assume 256-colour support.
THEMES=(dark vivid light cga colorblind)
THEME=dark
HOSTS_FROM_ARG=0

# Interval ladder, btop-style: + and - step through it rather than free-typing.
INTERVALS=(0.25 0.5 1 2 3 5 10 30)
IDX=2                      # -> 1 s
SHOW_BARS=1
SHOW_MODELS=1
SHOW_WARN=1
SHOW_EVENTS=1
EVENT_LIMITS=(5 10 20 50)
EVENT_MAX=10               # number of state changes retained; cycled with "l"
PAUSED=0
SHOW_HELP=0

# VRAM footprints demonstrated fully resident by hand (see README.md). Used only to draw
# bars. Absent host => "?" and no bar; nothing here is inferred.
#
# 0.0.32: both figures re-established with the layer count pinned (num_gpu 999), which
# reaches far closer to the edge of the card than letting Ollama choose the split -- see
# probe_load(). The .67 entry rose from 36.1 to 40.4 because 40.47 GB was demonstrated
# fully resident there; the old figure was where Ollama's own caution stopped, not where
# the hardware did.
#
# These are the largest footprints anyone has DEMONSTRATED, not hardware totals, and on a
# multi-GPU box the reachable figure varies by model. So they are floors exactly like a
# scanned figure, and are drawn with the same "+". This table was called VRAM_TOTAL and
# shown without the "+" until 0.0.46, which claimed a certainty no entry in it had, and
# which also hid any larger figure observed later: the table always won, so the bar
# pinned at red instead of showing the demonstrated headroom.
declare -A VRAM_FLOOR=( [192.168.100.37]=12.3 [192.168.100.67]=40.4 )

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ollamafarm"
CFG="$CFG_DIR/config"
CACHE_HOSTS="$CFG_DIR/hosts"
CACHE_VRAM="$CFG_DIR/vram"      # learned/probed ceilings, one "host<TAB>gb<TAB>source<TAB>epoch" per line
PROBE_LOG="$CFG_DIR/probe.log"  # progress written by the background probe worker
PROBE_LOCK="$CFG_DIR/probe.lock"

# ------------------------------------------------------------ config load -----
# Only ever read back keys we wrote, and validate each one: a corrupt or
# hand-edited config must not be able to break the run or inject commands.
load_config() {
  [ -r "$CFG" ] || return 0
  local k v t limit
  while IFS='=' read -r k v; do
    case "$k" in
      idx)          [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -lt "${#INTERVALS[@]}" ] && IDX="$v" ;;
      show_bars)    [[ "$v" =~ ^[01]$ ]] && SHOW_BARS="$v" ;;
      show_models)  [[ "$v" =~ ^[01]$ ]] && SHOW_MODELS="$v" ;;
      show_warn)    [[ "$v" =~ ^[01]$ ]] && SHOW_WARN="$v" ;;
      show_events)  [[ "$v" =~ ^[01]$ ]] && SHOW_EVENTS="$v" ;;
      event_max)    for limit in "${EVENT_LIMITS[@]}"; do
                      [ "$v" = "$limit" ] && EVENT_MAX="$v"
                    done ;;
      theme)        for t in "${THEMES[@]}"; do [ "$v" = "$t" ] && THEME="$v"; done ;;
    esac
  done < "$CFG"
}

save_config() {
  mkdir -p "$CFG_DIR" 2>/dev/null || return 0
  { printf 'idx=%s\n' "$IDX"
    printf 'show_bars=%s\n' "$SHOW_BARS"
    printf 'show_models=%s\n' "$SHOW_MODELS"
    printf 'show_warn=%s\n' "$SHOW_WARN"
    printf 'show_events=%s\n' "$SHOW_EVENTS"
    printf 'event_max=%s\n' "$EVENT_MAX"
    printf 'theme=%s\n' "$THEME"
  } > "$CFG.tmp" 2>/dev/null && mv -f "$CFG.tmp" "$CFG" 2>/dev/null
}

load_config

# --------------------------------------------------------------- arguments ----
# Print the leading comment block as help. Derived structurally rather than from
# hardcoded line numbers -- the previous "sed 2,60p" silently started dumping the
# licence header and truncating the usage text the moment anything above it grew.
usage() {
  awk 'NR>1 { if ($0 !~ /^#/) exit; print }' "$0" \
    | sed '/^# Copyright (C)/,/^# this program\. If not, see/d' \
    | sed 's/^#$//; s/^# \{0,1\}//' \
    | awk 'NF || p { print; p = NF }'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--interval)
      # Accept a raw seconds value by snapping to the nearest ladder rung, so the
      # flag and the +/- keys can never disagree about the current interval.
      [ $# -ge 2 ] || { echo "-n needs a value" >&2; exit 2; }
      # Validated first: awk reads a non-number as 0, so "-n abc" used to snap silently
      # to 0.25 s -- the fastest rate, and the wrong direction to fail in against a
      # shared server.
      [[ "$2" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] \
        || { echo "-n needs a number of seconds: $2" >&2; exit 2; }
      local_best=0; local_bestd=""
      for i in "${!INTERVALS[@]}"; do
        d=$(awk -v a="${INTERVALS[$i]}" -v b="$2" 'BEGIN{d=a-b; print (d<0?-d:d)}')
        if [ -z "$local_bestd" ] || awk -v x="$d" -v y="$local_bestd" 'BEGIN{exit !(x<y)}'; then
          local_bestd="$d"; local_best="$i"
        fi
      done
      IDX="$local_best"; shift 2 ;;
    -H|--hosts)   [ $# -ge 2 ] || { echo "-H needs a value" >&2; exit 2; }
                  HOSTS=$(echo "$2" | tr ',' ' '); HOSTS_FROM_ARG=1; shift 2 ;;
    -p|--port)    [ $# -ge 2 ] || { echo "-p needs a value" >&2; exit 2; }
                  PORT="$2"; shift 2 ;;
    -D|--discover) DO_DISCOVER=1; shift ;;
    --probe-worker) # internal: the detached worker started by "s" / auto-scan
                  PROBE_WORKER=1; shift ;;
    --probe-vram) # user-facing: scan now, in the foreground, printing progress.
                  # An optional host argument narrows it to one server.
                  PROBE_CLI=1; shift
                  if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then
                    HOSTS=$(echo "$1" | tr ',' ' '); HOSTS_FROM_ARG=1; shift
                  fi ;;
    --theme)      [ $# -ge 2 ] || { echo "--theme needs a value" >&2; exit 2; }
                  THEME=""
                  for t in "${THEMES[@]}"; do [ "$2" = "$t" ] && THEME="$2"; done
                  [ -n "$THEME" ] || { echo "unknown theme: $2 (have: ${THEMES[*]})" >&2; exit 2; }
                  shift 2 ;;
    --no-auto-scan) AUTO_SCAN=0; shift ;;
    --no-color)   WANT_COLOR=never; shift ;;
    --color)      WANT_COLOR=always; shift ;;
    -V|--version) printf 'ollamaFarm.sh %s\n' "$VERSION"; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown arg: $1  (try --help)" >&2; exit 2 ;;
  esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "port must be numeric: $PORT" >&2; exit 2; }

# ------------------------------------------------------------- dependencies ---
for dep in curl jq awk; do
  command -v "$dep" >/dev/null || { echo "$dep is required" >&2; exit 1; }
done

# Minimum versions, for the features actually used -- not a pin. curl and awk have no
# floor here: nothing newer than their long-standing basics is used.
#
# jq 1.5: --argjson, @tsv, first(), any(gen; cond) and endswith() all arrived in 1.5.
# Measured under 1.4: the per-model query fails, and because a failed query is meant to
# degrade rather than crash, every model line -- size, context, ttl, the SPLIT warning --
# silently disappears while the host line still shows the VRAM in use.
if [[ "$(jq --version 2>/dev/null)" =~ ^jq-([0-9]+)\.([0-9]+) ]] \
   && { [ "${BASH_REMATCH[1]}" -lt 1 ] \
        || { [ "${BASH_REMATCH[1]}" -eq 1 ] && [ "${BASH_REMATCH[2]}" -lt 5 ]; }; }; then
  echo "jq 1.5 or newer is required; found $(jq --version 2>/dev/null)" >&2
  exit 1
fi
# GNU date: latency is timed with %3N and keep-alive expiry is parsed with -d. BSD and
# busybox date print "%3N" literally or reject -d, which breaks the arithmetic.
if ! [[ "$(date +%s%3N 2>/dev/null)" =~ ^[0-9]+$ ]] \
   || ! date -d '2026-01-01T00:00:00Z' +%s >/dev/null 2>&1; then
  echo "GNU date (coreutils) is required" >&2
  exit 1
fi

# ------------------------------------------------------------------ colours ---
# Colour encodes STATE, never decoration: C_GRN = healthy/resident,
# C_RED = actively costing you performance now, C_YEL = about to change.
#
# A theme repaints those slots; it must never repurpose them. Whatever the palette,
# the healthy thing is fine and the bad thing is costing you throughput -- otherwise
# the display stops being readable at a glance, which is the only reason it exists.
# Most themes paint them green / yellow / red; cga cannot, and colorblind must not, so
# both keep the meanings in other colours instead.
#
# Slots: C_GRN good · C_YEL warning · C_RED bad · C_FIG figures · C_MODEL model names
#        C_DIM secondary text · C_B emphasis · C_REV inverted badge
use_color=1
case "$WANT_COLOR" in
  never)  use_color=0 ;;
  always) use_color=1 ;;
  auto)   { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; } || use_color=0 ;;
esac

apply_theme() {
  if [ "$use_color" != "1" ]; then
    C_RST=""; C_DIM=""; C_B=""; C_REV=""
    C_GRN=""; C_YEL=""; C_RED=""; C_FIG=""; C_MODEL=""
    C_HDR=""; C_HOST=""; C_LBL=""
    return 0
  fi
  C_RST=$'\e[0m'; C_B=$'\e[1m'; C_REV=$'\e[7m'
  case "$1" in
    vivid)
      # Deliberately loud, in the spirit of btop/abtop: structure in cyan, figures in
      # orange, identities in bright hues, and secondary text coloured rather than
      # merely dimmed -- which is what made the earlier version of this theme look
      # flat despite having saturated state colours.
      C_DIM=$'\e[38;5;244m'
      C_GRN=$'\e[1;38;5;47m'    # bright spring green — healthy
      C_YEL=$'\e[1;38;5;220m'   # gold — about to change
      C_RED=$'\e[1;38;5;198m'   # hot pink-red — costing you throughput
      C_FIG=$'\e[1;38;5;208m'   # orange — figures
      C_MODEL=$'\e[1;38;5;177m' # orchid — model names
      C_HDR=$'\e[1;38;5;51m'    # bright cyan — rules and section headings
      C_HOST=$'\e[1;38;5;123m'  # pale cyan, bold — host identity
      C_LBL=$'\e[38;5;80m'      # teal — field labels and units
      ;;
    light)
      # For a light terminal background: the ANSI defaults wash out on white, so
      # these are the dark ends of each hue, chosen for contrast rather than punch.
      # C_DIM is an explicit grey, because the dim *attribute* on a light background
      # renders as barely-there on several terminals.
      C_DIM=$'\e[38;5;242m'
      C_GRN=$'\e[38;5;28m'      # forest green
      C_YEL=$'\e[38;5;130m'     # dark amber (yellow is unreadable on white)
      C_RED=$'\e[38;5;124m'     # brick red
      # Figures are blue, not the burnt orange (166) they once were: that sat 9.4 CIEDE2000
      # from the amber warning (130) -- a latency figure read as a warning -- and had only
      # 3.8:1 contrast on white. Blue (25) is 21+ from every state colour, at 6.5:1.
      C_FIG=$'\e[38;5;25m'      # blue — figures
      C_MODEL=$'\e[38;5;90m'    # plum — model names
      C_HDR=$'\e[1;38;5;23m'    # deep teal — rules and section headings
      C_HOST=$'\e[1;38;5;236m'  # near-black, bold — host identity
      C_LBL=$'\e[38;5;24m'      # dark teal — field labels and units
      ;;
    cga)
      # IBM CGA palette 1, high intensity: cyan, magenta and white on black. There is no
      # green, yellow or red in it, so the meanings move -- they are never dropped:
      #   healthy = light cyan, bad = hot pink, about to change = white, bold AND
      #   underlined, so a warning cannot pass for plain white text.
      # Everything else uses the palette's dimmer steps: turquoise (CGA's low-intensity
      # cyan) for structure and figures, a dark magenta for model names, greys for the
      # rest. Measured as CIEDE2000 on the xterm-256 values: every state colour is at
      # least 16 from every other slot, and each sits at 7.7:1 contrast or more on black
      # except model names (5.1:1).
      C_DIM=$'\e[38;5;244m'
      C_GRN=$'\e[1;38;5;87m'    # light cyan — healthy
      C_YEL=$'\e[1;4;38;5;231m' # white, bold, underlined — about to change
      C_RED=$'\e[1;38;5;207m'   # hot pink (light magenta) — costing you throughput
      C_FIG=$'\e[38;5;37m'      # turquoise — figures
      C_MODEL=$'\e[38;5;133m'   # dark magenta — model names
      C_HDR=$'\e[1;38;5;37m'    # turquoise, bold — rules and section headings
      C_HOST=$'\e[1;38;5;248m'  # light grey, bold — host identity
      C_LBL=$'\e[38;5;248m'     # light grey — field labels and units
      ;;
    colorblind)
      # For red-green colour blindness, which affects roughly one man in twelve and makes
      # the green / red pair -- the most important distinction on this screen -- the
      # hardest one to see. State colours follow Okabe & Ito's colour-blind-safe palette:
      #   healthy = sky blue, about to change = yellow, bad = vermillion.
      # Measured with Machado et al.'s (2009) full-severity simulation, CIEDE2000, the
      # closest pair of state colours is 21.4 apart under deuteranopia and 32.2 under
      # protanopia; vivid manages 7.4 and 5.0, light 5.3 and 6.9. Everything that is not
      # a state is drawn in greys and one light purple, so no hue competes with them.
      C_DIM=$'\e[38;5;244m'
      C_GRN=$'\e[1;38;5;39m'    # sky blue — healthy
      C_YEL=$'\e[1;38;5;227m'   # yellow — about to change
      C_RED=$'\e[1;38;5;202m'   # vermillion — costing you throughput
      C_FIG=$'\e[38;5;255m'     # white — figures
      C_MODEL=$'\e[38;5;183m'   # light purple — model names
      C_HDR=$'\e[1;38;5;252m'   # light grey, bold — rules and section headings
      C_HOST=$'\e[1;38;5;255m'  # white, bold — host identity
      C_LBL=$'\e[38;5;250m'     # grey — field labels and units
      ;;
    *)
      # dark (default): plain ANSI 8-colour, so it works on anything, including a
      # tty with no 256-colour support, and inherits the user's own palette. The
      # extra slots fall back to bold/dim here rather than inventing hues.
      C_DIM=$'\e[2m'
      C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RED=$'\e[31m'
      C_FIG=$'\e[36m'; C_MODEL=$'\e[35m'
      C_HDR=$'\e[1m'; C_HOST=$'\e[1m'; C_LBL=$'\e[2m'
      ;;
  esac
}
apply_theme "$THEME"

# --------------------------------------------------------------- terminal -----
TTY_STATE=""
# $? must be captured on the very first line: this is an EXIT trap, so the pending
# exit status is whatever the script was exiting with. The previous version ended in a
# bare "exit 0", which silently turned every failure after the trap was installed into
# a success -- including --probe-vram's "no ceiling established" exit 1.
cleanup() {
  local rc=${1:-$?}
  # Restore what was actually changed, and nothing more. The escape sequences and the
  # config write belong to the TUI; --probe-vram and --probe-worker touch neither, and
  # emitting them there leaked "\e[?25h\e[0m" into piped output.
  [ -n "$TTY_STATE" ] && stty "$TTY_STATE" 2>/dev/null
  if [ "$PROBE_CLI" = "0" ] && [ "$PROBE_WORKER" = "0" ]; then
    [ -t 1 ] && printf '\e[?25h\e[0m\n'
    save_config
  fi
  exit "$rc"
}
trap cleanup INT TERM EXIT
if [ -t 0 ]; then
  TTY_STATE=$(stty -g 2>/dev/null || echo "")
  stty -echo 2>/dev/null
fi

# ---------------------------------------------------------------- helpers -----
# Frames are assembled into $OUT in-process with printf -v. This is not a style
# choice: render_host mutates the eviction-detector state (PREV_MODELS, PREV_TTL,
# EVENTS) and the /api/show cache. Capturing it with $(...) would run it in a
# subshell and silently discard every one of those updates -- the detector would
# never fire and the cache would re-query a shared server on every poll.
emit() { local _s; printf -v _s "$@"; OUT+="$_s"; }

# All float work goes through awk; bc is not assumed to be installed.
fgt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }   # a > b
flt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }   # a < b

num() { awk -v v="${1:-0}" 'BEGIN{printf "%.2f", (v==""?0:v)}'; }

bar() {  # bar <used> <total> <width>
  local used="$1" total="$2" w="$3"
  if ! fgt "$total" 0; then printf '%*s' "$w" ""; return; fi
  local pct filled i out="" col="$C_GRN"
  pct=$(awk -v u="$used" -v t="$total" 'BEGIN{p=u/t; print (p>1?1:p)}')
  filled=$(awk -v p="$pct" -v w="$w" 'BEGIN{printf "%d", p*w}')
  [ "$filled" -gt "$w" ] && filled="$w"
  [ "$filled" -lt 0 ] && filled=0
  fgt "$pct" 0.75 && col=$C_YEL
  fgt "$pct" 0.92 && col=$C_RED
  for ((i=0;i<filled;i++)); do out+="█"; done
  for ((i=filled;i<w;i++)); do out+="░"; done
  printf '%s%s%s' "$col" "$out" "$C_RST"
}

# ------------------------------------------------------ VRAM ceilings ---------
# Three sources, all of them LOWER BOUNDS, never totals, and all shown with a "+":
#   floor   - the VRAM_FLOOR table: a footprint demonstrated fully resident by hand
#   probed  - found by the "s" scan: the largest footprint that stayed fully resident
#   learned - observed passively: the largest fully-resident total ever seen
#
# Since every one of them says "at least this much fits", the largest one wins.
#
# An out-of-memory refusal during a scan does NOT lift a figure out of that category,
# which is the one thing this comment exists to say. It is tempting -- the card said no,
# so surely that is the ceiling -- but a refusal bounds THE MODEL BEING LOADED, not the
# machine. Measured here on the dual-GPU host, both idle, minutes apart:
#
#   qwen3.6:27b-q8_0            -> 40.47 GB resident before it refused
#   qwen3.6:27b-mtp-q8_0-ctx60k -> 34.69 GB resident before it refused
#
# Same box, same day, 5.8 GB apart. A model's layers divide unevenly across two cards,
# so one fills while the other still has room, and where that wall sits is a property of
# the model. Every scanned figure therefore keeps its "+".
#
# The distinction is load-bearing: a bar that silently means either "this is the
# capacity" or "it is at least this" would be worse than drawing no bar at all.
# See docs/vram-discovery.md for why a split event cannot be used as a measurement.
declare -A VRAM_LEARNED=()
declare -A VRAM_SOURCE=()

# Fold one ceiling into memory. Both kinds are lower bounds, so the larger figure wins
# and a smaller one never replaces it -- not even a fresh scan, which only reaches as far
# as the model it happened to pick. "probed" is sticky: it records that the host HAS been
# scanned, so auto-scan does not repeat it, whichever observation supplied the number.
merge_ceiling() {  # merge_ceiling <host> <gb> <probed|learned>
  local host="$1" gb="$2" src="$3"
  if [ -z "${VRAM_LEARNED[$host]:-}" ] || fgt "$gb" "${VRAM_LEARNED[$host]}"; then
    VRAM_LEARNED[$host]="$gb"
  fi
  [ "$src" = "probed" ] && VRAM_SOURCE[$host]=probed
  [ -n "${VRAM_SOURCE[$host]:-}" ] || VRAM_SOURCE[$host]=learned
}

load_vram_cache() {
  [ -r "$CACHE_VRAM" ] || return 0
  local h g src ts
  while IFS=$'\t' read -r h g src ts; do
    [ -n "$h" ] || continue
    [[ "$g" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
    case "$src" in probed|learned) ;; *) continue ;; esac
    merge_ceiling "$h" "$g" "$src"
  done < "$CACHE_VRAM"
}

# Several processes write this file: the TUI, its detached worker, a --probe-vram run,
# a second TUI. Each used to rewrite it from its own memory, so whoever saved last
# erased every entry the others had added since it started -- measured: a TUI's learned
# ceiling vanished when a concurrent --probe-vram finished. Re-reading and merging just
# before the write shrinks that to the gap between one read and one rename, and the
# per-process temp name stops two writers from interleaving inside one file.
save_vram_cache() {
  mkdir -p "$CFG_DIR" 2>/dev/null || return 0
  load_vram_cache
  local h tmp="$CACHE_VRAM.tmp.$$"
  : > "$tmp" 2>/dev/null || return 0
  for h in "${!VRAM_LEARNED[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "$h" "${VRAM_LEARNED[$h]}" "${VRAM_SOURCE[$h]:-learned}" "$(date +%s)" \
      >> "$tmp"
  done
  mv -f "$tmp" "$CACHE_VRAM" 2>/dev/null || rm -f "$tmp"
}

# Passive learning, free: /api/ps is already polled every frame. Only a total that
# was FULLY resident counts -- a split tells us capacity is near but is provably not
# a measurement of it (it can even be below a residency already observed to work).
note_resident_total() {  # note_resident_total <host> <gb> <any_split:0|1>
  local host="$1" gb="$2" split="$3"
  [ "$split" = "0" ] || return 0
  fgt "$gb" 0 || return 0
  # never downgrade a probed figure with a smaller passive observation
  if [ "${VRAM_SOURCE[$host]:-}" = "probed" ] && ! fgt "$gb" "${VRAM_LEARNED[$host]:-0}"; then
    return 0
  fi
  if fgt "$gb" "${VRAM_LEARNED[$host]:-0}"; then
    VRAM_LEARNED[$host]="$gb"
    # A passive observation that beats the scan is entirely expected: the scan reaches
    # only as far as ONE model could take it, and real traffic may run a model that
    # divides across the cards better. Both are lower bounds, so the larger simply wins.
    [ "${VRAM_SOURCE[$host]:-}" = "probed" ] || VRAM_SOURCE[$host]="learned"
    save_vram_cache
    event "$C_DIM" "$host: ceiling at least $(printf '%.1f' "$gb") GB (observed fully resident)"
  fi
}

# Echoes the best demonstrated floor in GB, or nothing when the host has none.
ceiling_for() {
  local host="$1" floor="${VRAM_FLOOR[$1]:-}" seen="${VRAM_LEARNED[$1]:-}"
  if [ -n "$floor" ] && { [ -z "$seen" ] || ! fgt "$seen" "$floor"; }; then
    printf '%s' "$floor"
  else
    printf '%s' "$seen"
  fi
}

load_vram_cache

# ------------------------------------------------------------- event log ------
# Ring buffer of state changes. This is where eviction thrash becomes visible:
# a snapshot cannot show it, only a diff between consecutive polls can.
declare -a EVENTS=()
declare -A PREV_MODELS=()   # host -> space-separated resident model names
declare -A PREV_TTL=()      # "host|model" -> seconds of keep_alive left when last seen
declare -A HOST_SEEN=()     # host -> 1 once it has answered at least once
declare -A SUSPECT_NAME=()  # host -> model that vanished early, awaiting confirmation
declare -A SUSPECT_AT=()    # host -> epoch seconds when that happened
# How long a suspected eviction stays open. A cold 33 GB MoE took ~70 s to become
# resident after displacing its predecessor, so the window must comfortably exceed
# that; 150 s covers a slower or busier host without being loose enough to blame an
# unrelated load minutes later.
SUSPECT_WINDOW=150

event() {  # event <colour> <text>
  EVENTS+=("$(date '+%H:%M:%S')|$1|$2")
  while [ "${#EVENTS[@]}" -gt "$EVENT_MAX" ]; do EVENTS=("${EVENTS[@]:1}"); done
}

cycle_event_max() {
  local i
  for i in "${!EVENT_LIMITS[@]}"; do
    if [ "${EVENT_LIMITS[$i]}" = "$EVENT_MAX" ]; then
      EVENT_MAX="${EVENT_LIMITS[$(( (i + 1) % ${#EVENT_LIMITS[@]} ))]}"
      break
    fi
  done
  # Shrinking the limit takes effect immediately instead of waiting for enough new
  # events to arrive. The oldest entries are the ones discarded by the ring buffer.
  while [ "${#EVENTS[@]}" -gt "$EVENT_MAX" ]; do EVENTS=("${EVENTS[@]:1}"); done
  save_config
}

# ------------------------------------------------- per-model config warnings ---
# /api/show is queried once per (host,model) and cached: the parameters do not
# change while a model is resident, and this must not add load to a shared box.
declare -A SHOW_CACHE=()

MW=""                      # set by model_warnings; read immediately after the call
model_warnings() {  # model_warnings <host> <model>  -> sets $MW
  local host="$1" model="$2" key="$1|$2"
  MW=""
  if [ -n "${SHOW_CACHE[$key]+x}" ]; then MW="${SHOW_CACHE[$key]}"; return; fi

  local params w=""
  params=$(curl -s --max-time 3 -X POST "http://$host:$PORT/api/show" \
             -H 'Content-Type: application/json' \
             -d "$(jq -nc --arg m "$model" '{model:$m}')" 2>/dev/null \
           | jq -r '.parameters // ""' 2>/dev/null)

  if [ -n "$params" ]; then
    local pp nc
    pp=$(printf '%s\n' "$params" | awk '$1=="presence_penalty"{print $2; exit}')
    nc=$(printf '%s\n' "$params" | awk '$1=="num_ctx"{print $2; exit}')
    if [ -n "$pp" ] && fgt "$pp" 0; then
      w+="presence_penalty=$pp (~35% slower — bake 0); "
    fi
    if [ -z "$nc" ]; then
      w+="no baked num_ctx (16k cap via /v1/messages, tool calls die past it); "
    fi
  fi
  SHOW_CACHE["$key"]="${w% }"
  MW="${SHOW_CACHE[$key]}"
}

# ------------------------------------------------------------- discovery ------
# Probe /api/version across the /24 of each already-known host. Parallel, short
# timeout, and it never writes to the servers. VRAM is not probed (see header).
discover() {
  local seeds="$1" nets="" ip net found=""
  for ip in $seeds; do
    net="${ip%.*}"
    case " $nets " in *" $net "*) ;; *) nets+=" $net" ;; esac
  done
  [ -z "$nets" ] && return 1

  local tmp; tmp=$(mktemp) || return 1
  for net in $nets; do
    for i in $(seq 1 254); do printf '%s.%s\n' "$net" "$i"; done
  done | xargs -P 64 -I{} sh -c \
      'curl -s --max-time 0.6 "http://{}:'"$PORT"'/api/version" \
         | grep -q version && echo {}' > "$tmp" 2>/dev/null

  found=$(sort -t. -k4 -n "$tmp" 2>/dev/null | tr '\n' ' ')
  rm -f "$tmp"
  if [ -n "${found// /}" ]; then
    HOSTS="${found% }"
    mkdir -p "$CFG_DIR" 2>/dev/null && printf '%s\n' "$HOSTS" > "$CACHE_HOSTS" 2>/dev/null
    event "$C_GRN" "discovery: $(echo "$HOSTS" | wc -w) host(s) — $HOSTS"
    return 0
  fi
  event "$C_YEL" "discovery found nothing; keeping previous host list"
  return 1
}

# Use a cached discovery result when the caller did not pin hosts explicitly.
if [ "$HOSTS_FROM_ARG" = "0" ] && [ -r "$CACHE_HOSTS" ]; then
  cached=$(tr -d '\n' < "$CACHE_HOSTS")
  [ -n "${cached// /}" ] && HOSTS="$cached"
fi
[ "$DO_DISCOVER" = "1" ] && discover "$HOSTS"

# --------------------------------------------------------------- rendering ----
render_host() {
  local host="$1" base="http://$1:$PORT"
  local ver
  ver=$(curl -s --max-time 1.5 "$base/api/version" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)

  if [ -z "$ver" ]; then
    emit '  %s%-16s%s  %sUNREACHABLE%s %s(USB ethernet adapter up?)%s\n' \
      "$C_HOST" "$host" "$C_RST" "$C_RED" "$C_RST" "$C_DIM" "$C_RST"
    # A host that drops out should not look like a host whose models expired.
    if [ -n "${PREV_MODELS[$host]:-}" ]; then
      event "$C_RED" "$host went unreachable (was holding: ${PREV_MODELS[$host]})"
      PREV_MODELS[$host]=""
    fi
    return
  fi

  HOST_SEEN[$host]=1

  local t0 t1 lat ps
  t0=$(date +%s%3N)
  ps=$(curl -s --max-time 2.5 "$base/api/ps" 2>/dev/null)
  t1=$(date +%s%3N); lat=$(( t1 - t0 ))

  # Malformed or empty JSON must degrade to "0 models", never crash the loop.
  local n
  n=$(printf '%s' "$ps" | jq -r '.models | length' 2>/dev/null) || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0

  local used any_split
  used=$(printf '%s' "$ps" | jq -r '[.models[]?.size_vram] | add // 0 | ./1e9' 2>/dev/null) || used=0
  used=$(num "$used")
  # 1 if any resident model is split to CPU; a split total must not train the ceiling.
  any_split=$(printf '%s' "$ps" \
    | jq -r 'if any(.models[]?; .size_vram < .size - 5e7) then 1 else 0 end' 2>/dev/null) || any_split=1
  [[ "$any_split" =~ ^[01]$ ]] || any_split=1
  [ "$n" -gt 0 ] && note_resident_total "$host" "$used" "$any_split"

  local total
  total=$(ceiling_for "$host")

  emit '  %s%-16s%s %sollama %-7s%s ' "$C_HOST" "$host" "$C_RST" "$C_LBL" "$ver" "$C_RST"
  if [ -n "$total" ]; then
    [ "$SHOW_BARS" = "1" ] && emit '%s ' "$(bar "$used" "$total" 22)"
    # "+" marks a lower bound: at least this much fits, the true ceiling may be more.
    # Every source is one, so every figure carries it.
    emit '%s%5.1f%s/%s%s+%s GB ' "$C_FIG" "$used" "$C_RST" "$C_LBL" "$total" "$C_RST"
  else
    emit '%s%5.1f GB%s/%s?%s ' "$C_FIG" "$used" "$C_RST" "$C_DIM" "$C_RST"
  fi
  local lcol=$C_FIG
  [ "$lat" -gt 400 ] && lcol=$C_YEL
  [ "$lat" -gt 1500 ] && lcol=$C_RED
  emit '%s%4dms%s\n' "$lcol" "$lat" "$C_RST"

  # ---- diff against the previous poll: eviction, expiry, arrival ----
  local now cur_names=""
  now=$(date +%s)
  if [ "$n" -gt 0 ]; then
    cur_names=$(printf '%s' "$ps" | jq -r '.models[]?.name' 2>/dev/null | tr '\n' ' ')
  fi
  local prev="${PREV_MODELS[$host]:-}"
  local appeared="" vanished="" nm
  for nm in $cur_names; do
    case " $prev " in *" $nm "*) ;; *) appeared+="$nm " ;; esac
  done
  for nm in $prev; do
    case " $cur_names " in *" $nm "*) ;; *) vanished+="$nm " ;; esac
  done

  # Eviction is NOT atomic, and that shaped this logic. Measured on .67: Ollama
  # unloaded the 9b at 14:09:40 and the replacing 33 GB MoE only became resident at
  # 14:09:55 -- 15 s later, and up to ~70 s for a cold MoE. So in the poll where a
  # model disappears there is usually nothing new to blame it on yet. A model that
  # vanishes with keep_alive still on the clock is therefore recorded as a *suspected*
  # eviction, and confirmed when a different model turns up within the window below.
  if [ -n "${vanished// /}" ]; then
    for nm in $vanished; do
      local ttl="${PREV_TTL["$host|$nm"]:-0}"
      if [ -n "${appeared// /}" ]; then
        event "$C_RED" "EVICTED $nm on $host → ${appeared% } (~70 s reload penalty)"
      elif [ "$ttl" -gt 30 ]; then
        event "$C_YEL" "$nm vanished on $host, ${ttl}s ttl left — suspected eviction, watching"
        SUSPECT_NAME[$host]="$nm"
        SUSPECT_AT[$host]="$now"
      else
        event "$C_DIM" "$nm unloaded on $host (keep_alive expired)"
      fi
    done
  elif [ -n "${appeared// /}" ] && [ -n "${prev// /}" ]; then
    event "$C_YEL" "$host now holds $n models — they cannot both fit; a reload is coming"
  elif [ -n "${appeared// /}" ]; then
    local sname="${SUSPECT_NAME[$host]:-}" sat="${SUSPECT_AT[$host]:-0}"
    if [ -n "$sname" ] && [ $(( now - sat )) -le "$SUSPECT_WINDOW" ]; then
      event "$C_RED" "EVICTED $sname on $host → ${appeared% } after $(( now - sat ))s (~70 s reload penalty)"
      SUSPECT_NAME[$host]=""
    else
      event "$C_GRN" "loaded ${appeared% } on $host"
    fi
  fi
  # A suspicion that never gets confirmed is dropped rather than left to mislabel a
  # later, unrelated load as an eviction.
  if [ -n "${SUSPECT_NAME[$host]:-}" ] && \
     [ $(( now - ${SUSPECT_AT[$host]:-0} )) -gt "$SUSPECT_WINDOW" ]; then
    SUSPECT_NAME[$host]=""
  fi
  PREV_MODELS[$host]="$cur_names"

  if [ "$n" = "0" ]; then
    emit '      %sidle — no model resident%s\n' "$C_DIM" "$C_RST"
    return
  fi

  # ---- per-model detail ----
  if [ "$SHOW_MODELS" = "1" ]; then
    local name vram size ctx exp quant psize
    while IFS=$'\t' read -r name vram size ctx exp quant psize; do
      [ -z "$name" ] && continue
      local split="" scol="$C_GRN"
      if flt "$vram" "$(awk -v s="$size" 'BEGIN{print s-0.05}')"; then
        split=" ⚠ SPLIT→CPU (5.3x slower)"; scol="$C_RED"
      fi

      local left="" lc="$C_DIM" secs=0
      if [ -n "$exp" ]; then
        local es
        es=$(date -d "$exp" +%s 2>/dev/null) || es=0
        if [ "$es" -gt 0 ]; then
          secs=$(( es - now ))
          if   [ "$secs" -lt 0 ]    ; then left="expired"
          elif [ "$secs" -lt 60 ]   ; then left="${secs}s"; lc="$C_YEL"
          elif [ "$secs" -lt 3600 ] ; then left="$(( secs/60 ))m$(( secs%60 ))s"
          else                            left="$(( secs/3600 ))h$(( (secs%3600)/60 ))m"
          fi
        fi
      fi
      [ "$secs" -lt 0 ] && secs=0
      PREV_TTL["$host|$name"]="$secs"

      emit '      %s%-30s%s %s%6s %-7s%s %s%5.2f/%-5.2f GB%s %sctx %-7s%s %sttl %-7s%s%s%s%s\n' \
        "$C_MODEL" "$name" "$C_RST" \
        "$C_LBL" "$psize" "$quant" "$C_RST" \
        "$scol" "$vram" "$size" "$C_RST" \
        "$C_LBL" "$ctx" "$C_RST" \
        "$lc" "$left" "$C_RST" \
        "$scol" "$split" "$C_RST"

      if [ "$SHOW_WARN" = "1" ]; then
        model_warnings "$host" "$name"
        [ -n "$MW" ] && emit '        %s↳ %s%s\n' "$C_YEL" "$MW" "$C_RST"
      fi
    done < <(printf '%s' "$ps" | jq -r '.models[]? |
        [ .name, (.size_vram/1e9), (.size/1e9), (.context_length // 0),
          (.expires_at // ""), (.details.quantization_level // "?"),
          (.details.parameter_size // "?") ] | @tsv' 2>/dev/null)
  fi

}

help_overlay() {
  emit '  %s%sKEYS%s\n' "$C_HDR" "$C_REV" "$C_RST"
  emit '    %s- +%s  refresh faster / slower    %sp%s  pause/resume   %sq%s  quit\n' \
    "$C_B" "$C_RST" "$C_B" "$C_RST" "$C_B" "$C_RST"
  emit '    %sv%s    VRAM bars                  %sm%s  model detail   %sw%s  warnings\n' \
    "$C_B" "$C_RST" "$C_B" "$C_RST" "$C_B" "$C_RST"
  emit '    %se%s    event log                  %sd%s  re-discover    %st%s  theme (%s)\n' \
    "$C_B" "$C_RST" "$C_B" "$C_RST" "$C_B" "$C_RST" "$THEME"
  emit '    %sl%s    event history (%s entries)\n' \
    "$C_B" "$C_RST" "$EVENT_MAX"
  emit '    %ss%s    scan idle hosts for their VRAM ceiling (minutes on a large box)\n' \
    "$C_B" "$C_RST"
  emit '    %sh ?%s  close this help\n' "$C_B" "$C_RST"
  emit '  %sWatched failure modes: eviction thrash (~70 s reload), split placement\n' "$C_DIM"
  emit '  (5.3x slower), missing baked num_ctx (16k cap, tool calls die),\n'
  emit '  presence_penalty != 0 (~35%% slower). See README.md.%s\n' "$C_RST"
}

# --------------------------------------------------------------- VRAM probe ----
# Finds the largest footprint that stays FULLY RESIDENT on a host, by loading a model
# with every layer pinned to the GPU and binary-searching num_ctx until the card
# refuses the allocation. The refusal is the point: it puts a lid on the search, so the
# result is a bracket a few percent wide rather than the open-ended "at least this
# much" that passive observation and the old auto-offload scan could ever produce.
#
# Three rules make this safe to bind to a key on somebody else's server:
#   1. an idle host only, re-checked before every load. If anything is resident the host
#      is skipped, loudly. Evicting a colleague's model costs them a ~70 s reload, so the
#      scan never does it.
#   2. keep_alive 0 on every load, so nothing is left behind.
#   3. it runs detached, and the UI keeps refreshing. Measured: 103 s on the 12 GB box
#      (seven too-large models rejected at ~8 s each before one fitted) and ~3 min on the
#      dual-GPU box, because reach requires a large model and a 33 GB model alone takes
#      ~70 s to load.
plog() {
  printf '%s\n' "$*" >> "$PROBE_LOG"
  [ "$PROBE_CLI" = "1" ] && printf '%s\n' "$*"
  return 0
}

# Load a model at a given num_ctx with EVERY layer forced onto the GPU, then report
# "<size_vram_gb> <verdict>" where verdict is one of ok | oom | split.
#
# "num_gpu: 999" is the whole point of this function, and the reason the figures it
# produces are so much tighter than the ones the first version of the scan produced.
#
# Left to itself, Ollama picks the layer count from its own pre-flight estimate, and
# that estimate is deliberately conservative: it keeps a reserve, it can only move
# whole layers, and it would rather split to system RAM than risk an allocation
# failure. So the largest footprint Ollama will VOLUNTARILY place is well below what
# the card actually holds -- which is exactly why the auto-offload scan reported
# 36.1 GB for a box that in fact takes 38.8 GB.
#
# Pinning the layer count removes the estimate from the loop and makes the CUDA
# allocator answer the question directly:
#
#   the load succeeds -> that many bytes genuinely fit. A lower bound, but a tight one.
#   the load OOMs     -> this model cannot fit at that context. It narrows this search,
#                        but does not establish the machine's ceiling: layer placement
#                        can make another model reach higher on the same GPUs.
#
# See docs/vram-discovery.md; the failed load is contained in the llama-server
# subprocess and never takes the Ollama daemon itself down.
probe_load() {  # probe_load <host> <model> <ctx>
  local host="$1" model="$2" ctx="$3" base="http://$1:$PORT" resp err r
  resp=$(curl -s --max-time 900 -X POST "$base/api/generate" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$model" --argjson c "$ctx" \
          '{model:$m,keep_alive:"60s",options:{num_gpu:999,num_ctx:$c}}')" 2>/dev/null)
  err=$(printf '%s' "$resp" | jq -r '.error // ""' 2>/dev/null)

  # An out-of-memory refusal is a RESULT, not a failure: it is the upper bound. Any
  # other error (missing model, host gone) is not, and must not be read as one.
  if [ -n "$err" ]; then
    case "$err" in
      *"out of memory"*|*"cudaMalloc"*|*"unable to allocate"*|*"failed to allocate"*)
        printf '0 oom'; return ;;
      *) printf '0 err'; return ;;
    esac
  fi

  # Measure THIS model by name, never ".models[0]": if anything else became resident
  # during the load, the first entry may be somebody else's model -- which once made a
  # colleague's 4 GB model read as the scan's own result.
  r=$(curl -s --max-time 10 "$base/api/ps" 2>/dev/null \
      | jq -r --arg m "$model" 'first(.models[]? | select(.name == $m))
          | "\(.size_vram/1e9) \(if .size_vram < .size - 5e7 then "split" else "ok" end)"' 2>/dev/null)
  curl -s --max-time 60 -X POST "$base/api/generate" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$model" '{model:$m,keep_alive:0}')" >/dev/null 2>&1
  [ -n "$r" ] && printf '%s' "$r" || printf '0 err'
}

# Names of anything resident on <host> other than <model>, comma-separated; empty means
# the host is still ours to load on. A host that does not answer, or answers garbage,
# reports itself as busy: the safe reading of "unknown" is "somebody may be using it".
foreign_resident() {  # foreign_resident <host> <model>
  local ps
  ps=$(curl -sf --max-time 5 "http://$1:$PORT/api/ps" 2>/dev/null) \
    || { printf '(host not answering)'; return; }
  printf '%s' "$ps" | jq -r --arg m "$2" '[.models[]?.name | select(. != $m)] | join(", ")' \
    2>/dev/null || printf '(unreadable /api/ps)'
}

# Hosts that produced a RESULT in THIS process. --probe-vram decides its exit status from
# this, never from VRAM_SOURCE, which also holds whatever a previous run left in the cache.
PROBED_NOW=""

probe_host() {
  local host="$1" base="http://$1:$PORT"
  local ps n
  ps=$(curl -s --max-time 5 "$base/api/ps" 2>/dev/null)
  n=$(printf '%s' "$ps" | jq -r '.models | length' 2>/dev/null) || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if [ "$n" != "0" ]; then
    plog "SKIP $host — not idle, holding: $(printf '%s' "$ps" | jq -r '[.models[].name]|join(", ")' 2>/dev/null)"
    return 0
  fi

  # Largest models first: reach is what matters. A small model on a big box stays
  # resident at its maximum context and reveals nothing about the ceiling.
  local models
  models=$(curl -s --max-time 10 "$base/api/tags" 2>/dev/null \
           | jq -r '.models[]? | "\(.size)\t\(.name)"' 2>/dev/null | sort -rn | cut -f2)
  [ -n "$models" ] || { plog "SKIP $host — no models on the server"; return 0; }

  # best  = largest footprint seen FULLY RESIDENT      -> lower bound on the ceiling
  # capped = 1 once a load has been refused for OOM    -> the ceiling is bracketed
  #
  # Two separate budgets, because the two failures cost wildly different amounts of
  # time. A model whose weights alone overflow the card is rejected by the allocator in
  # a few seconds and tells us only "too big, next one" -- on a 12 GB box holding
  # several 17-30 GB models that happens repeatedly before anything fits, so charging
  # those to the same small budget as a real attempt made the scan give up before it
  # reached a model it could load. Rejections are therefore counted separately and
  # allowed to run further; the search still stops at the first model that does load.
  # The idle check above is only a snapshot, and a scan runs for minutes. A colleague
  # who starts work on this host mid-scan must not have their model displaced by the
  # next num_gpu:999 load, so every load is preceded by a fresh check and the scan stops
  # the moment anyone else is resident. This narrows the race to the gap between one
  # /api/ps and one /api/generate; the API offers no way to close it entirely.
  local best=0 capped=0 rejected=0 busy="" model
  for model in $models; do
    # 12, not a smaller number: the .37 box needed 7 rejections before reaching a model
    # it could hold, and a rejection costs only ~8 s because the allocator refuses long
    # before any weights are transferred.
    [ "$rejected" -ge 12 ] && break

    local maxctx
    maxctx=$(curl -s --max-time 10 -X POST "$base/api/show" -H 'Content-Type: application/json' \
             -d "$(jq -nc --arg m "$model" '{model:$m}')" 2>/dev/null \
             | jq -r '.model_info | to_entries | map(select(.key|endswith(".context_length"))) | .[0].value // 262144' 2>/dev/null)
    [[ "$maxctx" =~ ^[0-9]+$ ]] || maxctx=262144

    plog "probe $host: $model (max ctx $maxctx)"
    local lo=2048 hi="$maxctx" res vram verdict
    busy=$(foreign_resident "$host" "$model"); [ -n "$busy" ] && break
    res=$(probe_load "$host" "$model" "$lo"); vram="${res%% *}"; verdict="${res##* }"
    case "$verdict" in
      oom)   plog "  $model will not fit even at ctx $lo — trying a smaller model"
             capped=1; rejected=$((rejected + 1)); continue ;;
      split) plog "  $model splits even at ctx $lo — trying a smaller model"
             rejected=$((rejected + 1)); continue ;;
      err)   plog "  $model could not be loaded — trying a smaller model"
             rejected=$((rejected + 1)); continue ;;
    esac
    fgt "$vram" "$best" && best="$vram"
    plog "  ctx $lo: resident $(printf '%.2f' "$vram") GB"

    # Binary search the largest num_ctx that still fits entirely on the GPU. Bounded
    # at 7 loads. Every "oom" narrows the bracket for this model from above; the best
    # successful load remains a lower bound on what the machine can hold.
    local i=0
    while [ "$i" -lt 7 ] && [ $(( hi - lo )) -gt 4096 ]; do
      i=$((i + 1))
      local mid=$(( (lo + hi) / 2 ))
      busy=$(foreign_resident "$host" "$model"); [ -n "$busy" ] && break
      res=$(probe_load "$host" "$model" "$mid"); vram="${res%% *}"; verdict="${res##* }"
      case "$verdict" in
        ok)    lo="$mid"; fgt "$vram" "$best" && best="$vram"
               plog "  ctx $mid: resident $(printf '%.2f' "$vram") GB" ;;
        oom)   hi="$mid"; capped=1
               plog "  ctx $mid: OUT OF MEMORY — the ceiling is below this" ;;
        split) hi="$mid"
               plog "  ctx $mid: SPLIT — the ceiling is below this" ;;
        *)     hi="$mid"
               plog "  ctx $mid: load failed — treating as above the ceiling" ;;
      esac
    done
    break
  done

  # Whatever was demonstrated before the host turned busy is still a real fit and is
  # kept below; the scan simply goes no further.
  [ -n "$busy" ] && plog "SKIP $host — became busy mid-scan, holding: $busy; scan stopped"

  if fgt "$best" 0; then
    # $capped records that the card refused something larger, which is worth saying in
    # the log -- it means the search ended at a wall rather than running out of context
    # to ask for. It does NOT promote the figure: the wall belongs to this model, not to
    # the machine. See the note above ceiling_for().
    local why="stopped at the model's context limit"
    [ "$capped" = "1" ] && why="the GPU refused more of this model"
    plog "RESULT $host $(printf '%.2f' "$best") probed"
    PROBED_NOW+="$host "
    plog "  ($why)"
    # Persist from the worker as well, so a standalone --probe-worker run is not lost
    # if no UI is watching. Read-modify-write, so a concurrently learned entry for a
    # different host survives.
    merge_ceiling "$host" "$(printf '%.2f' "$best")" probed
    save_vram_cache
  else
    plog "SKIP $host — could not place any model fully in VRAM"
  fi
}

probe_worker() {
  load_vram_cache
  # The detached path gets its directory from start_probe, but --probe-vram calls this
  # function straight from main and used to inherit nothing: on a machine that had never
  # run the TUI, every single plog line failed with "No such file or directory" while
  # the scan itself worked. Create it here, where both entry points pass through.
  mkdir -p "$CFG_DIR" 2>/dev/null

  # --probe-vram enters this function directly and so never took the lock that
  # start_probe takes for the detached path. That left two holes: pressing "s" in a
  # running TUI would happily put a SECOND scan on the same host, and this run would
  # then delete a lock it had never owned, freeing the way for a third. Both matter
  # more now that a scan deliberately pushes the GPU to an out-of-memory refusal --
  # two of them racing between the idle check and the load is exactly what the lock is
  # for. The detached path is not re-checked here: start_probe already did, and its
  # lock names this very process.
  if [ "$PROBE_CLI" = "1" ]; then
    if probe_running; then
      printf 'a ceiling scan is already running (pid %s)\n' \
        "$(cat "$PROBE_LOCK" 2>/dev/null)" >&2
      return 1
    fi
    echo $$ > "$PROBE_LOCK" 2>/dev/null
  fi

  : > "$PROBE_LOG"
  plog "scan started $(date '+%H:%M:%S')"
  local h
  for h in $HOSTS; do probe_host "$h"; done
  plog "scan finished $(date '+%H:%M:%S')"
  rm -f "$PROBE_LOCK"
}

# Launch the detached worker, refusing to stack two scans on top of each other.
probe_running() {
  [ -f "$PROBE_LOCK" ] && kill -0 "$(cat "$PROBE_LOCK" 2>/dev/null)" 2>/dev/null
}

start_probe() {  # start_probe [host ...]   (defaults to every known host)
  local targets="${*:-$HOSTS}"
  if probe_running; then
    event "$C_YEL" "a ceiling scan is already running"
    return 0
  fi
  [ -n "${targets// /}" ] || return 0
  # Only the scan needs these, so their absence disables scanning, not the monitor.
  if ! command -v setsid >/dev/null || ! command -v nohup >/dev/null; then
    event "$C_RED" "cannot scan: setsid and nohup are required to detach the worker"
    return 0
  fi
  mkdir -p "$CFG_DIR" 2>/dev/null
  # Through bash explicitly, so a copy without the executable bit still works.
  setsid nohup bash "$SELF" --probe-worker -H "$(echo "$targets" | tr ' ' ',')" -p "$PORT" \
    </dev/null >/dev/null 2>&1 &
  echo $! > "$PROBE_LOCK"
  PROBE_OFFSET=0
  event "$C_GRN" "ceiling scan started: ${targets// /, } — minutes on a large box"
}

# Bootstrap a ceiling for hosts that have none worth trusting.
#
# Passive learning cannot get started on an idle host: with nothing resident there is
# nothing to observe. The scan solves exactly that -- it loads a model itself and then
# expands num_ctx upward from there -- so it is triggered automatically rather than
# waiting for someone to press "s".
#
# Only for hosts that are idle (so nothing is ever evicted) and whose ceiling is either
# unknown or merely "learned". A hand-demonstrated table figure or an earlier probe is
# left alone -- re-measuring it would mean writing to the server for little gain -- and each host is attempted once per session so a failure cannot loop.
declare -A AUTO_TRIED=()
maybe_auto_scan() {
  [ "$AUTO_SCAN" = "1" ] || return 0
  probe_running && return 0
  local h cand=""
  for h in $HOSTS; do
    [ -n "${AUTO_TRIED[$h]:-}" ] && continue
    [ -n "${VRAM_FLOOR[$h]:-}" ] && continue                  # demonstrated by hand
    [ "${VRAM_SOURCE[$h]:-}" = "probed" ] && continue          # already scanned
    [ -n "${PREV_MODELS[$h]:-}" ] && continue                 # busy: never evict
    [ -z "${HOST_SEEN[$h]:-}" ] && continue                   # not reached yet
    cand+="$h "
  done
  [ -n "${cand// /}" ] || return 0
  for h in $cand; do AUTO_TRIED[$h]=1; done
  event "$C_DIM" "no known ceiling for ${cand% } — bootstrapping a scan (idle, nothing evicted)"
  start_probe "${cand% }"
}

# Fold new worker output into the event log, and adopt any RESULT it reports.
#
# The offset starts at the CURRENT end of the log, not at zero. Starting at zero
# replayed a previous session's scan on every launch: its events reappeared as if
# live, and -- worse -- its RESULT lines were re-adopted, resurrecting a ceiling the
# user had just deleted from the cache. Only output produced after this process
# started is ours to read.
PROBE_OFFSET=0
[ -r "$PROBE_LOG" ] && PROBE_OFFSET=$(wc -c < "$PROBE_LOG" 2>/dev/null || echo 0)
[[ "$PROBE_OFFSET" =~ ^[0-9]+$ ]] || PROBE_OFFSET=0
drain_probe_log() {
  [ -r "$PROBE_LOG" ] || return 0
  local size; size=$(wc -c < "$PROBE_LOG" 2>/dev/null) || return 0
  # Every scan truncates the log when it starts. A scan started by ANOTHER process (a
  # --probe-vram in a second terminal) does so behind this one's back, and the offset
  # then points past the end of the new log: its lines, RESULT included, were silently
  # skipped until the file grew past the old size. A shrunk file means a new log.
  [ "$size" -lt "$PROBE_OFFSET" ] && PROBE_OFFSET=0
  [ "$size" -le "$PROBE_OFFSET" ] && return 0
  local line result_host result_g
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      RESULT*) read -r _ result_host result_g _ <<< "$line"
               if [ -n "$result_host" ] && [[ "$result_g" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                 merge_ceiling "$result_host" "$result_g" probed
                 save_vram_cache
                 event "$C_GRN" "$result_host: ceiling at least $result_g GB (probed)"
               else
                 event "$C_YEL" "ignored malformed probe result"
               fi ;;
      SKIP*)   event "$C_YEL" "${line#SKIP }" ;;
      *)       event "$C_DIM" "$line" ;;
    esac
  done < <(tail -c "+$((PROBE_OFFSET + 1))" "$PROBE_LOG" 2>/dev/null)
  PROBE_OFFSET="$size"
}

# ------------------------------------------------------------------- main ------
if [ "$PROBE_WORKER" = "1" ]; then probe_worker; exit 0; fi

# --probe-vram: same scan, in the foreground, so it is usable from a script or a
# terminal without the TUI. Exits non-zero when no ceiling could be established --
# every host busy, no model would fit, or another scan already holds the lock -- so a
# caller can tell. Success is judged only by results produced in this process: checking
# VRAM_SOURCE instead, as an earlier version did, read ceilings that load_vram_cache had
# picked up from a PREVIOUS run, and reported success for a host this run had skipped.
if [ "$PROBE_CLI" = "1" ]; then
  probe_worker || exit 1
  [ -n "$PROBED_NOW" ] && exit 0
  echo "no ceiling established (hosts busy, or no model fits)" >&2
  exit 1
fi

printf '\e[?25l'   # hide cursor
FIRST=1
while true; do
  INTERVAL="${INTERVALS[$IDX]}"
  OUT=""

  # Terminal geometry, refreshed every frame so a resize is picked up immediately.
  # Rows drive the clipping guard; columns size the header rule, which was
  # previously a hardcoded run of box characters and so was the wrong length at
  # every window size but one.
  if [ -t 1 ]; then
    read -r TERM_ROWS TERM_COLS < <( { stty size 2>/dev/null || echo "24 80"; } )
  else
    TERM_ROWS=24; TERM_COLS=80
  fi
  [[ "$TERM_ROWS" =~ ^[0-9]+$ ]] && [ "$TERM_ROWS" -gt 0 ] || TERM_ROWS=24
  [[ "$TERM_COLS" =~ ^[0-9]+$ ]] && [ "$TERM_COLS" -gt 20 ] || TERM_COLS=80

  # A paused view says how to resume, and any section that a persisted toggle has
  # switched off is named in the header. Without that, a toggle saved in a previous
  # session silently hides the most important data and looks like a broken tool.
  # The badge is kept as a plain twin as well: its *visible* width is needed to
  # size the rule, and the coloured version is full of escape bytes that ${#...}
  # would count as characters.
  hdr_state=""; hdr_plain=""
  if [ "$PAUSED" = "1" ]; then
    hdr_plain="   PAUSED — press p to resume "
    hdr_state="  ${C_YEL}${C_REV} PAUSED — press p to resume ${C_RST}"
  fi
  off=""; off_plain=""
  [ "$SHOW_MODELS" = "0" ] && off_plain+=" models:off(m)"
  [ "$SHOW_BARS"   = "0" ] && off_plain+=" bars:off(v)"
  [ "$SHOW_WARN"   = "0" ] && off_plain+=" warnings:off(w)"
  [ "$SHOW_EVENTS" = "0" ] && off_plain+=" events:off(e)"
  if [ -n "$off_plain" ]; then
    off="  ${C_YEL}hidden:${off_plain}${C_RST}"
    off_plain="  hidden:${off_plain}"
  fi

  # The rule spans exactly the status line beneath it -- not the whole terminal,
  # which left a long tail of box characters running past the text. So the status
  # line is built as a plain twin first and measured, and the rule is cut to that
  # width. ${#...} on the coloured version would count escape bytes as characters.
  printf -v keyhint '[+ slower  - faster  v m w e  l history:%s  d s  p pause  h help  q quit]' \
    "$EVENT_MAX"
  stamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf -v line2_plain '  %s   every %ss   %s%s' "$stamp" "$INTERVAL" "$keyhint" "$off_plain"

  # The version rides in the title, so a screenshot or a pasted frame identifies
  # exactly which build produced it.
  hdr_title="┌─ Ollama farm ${VERSION} "
  # Two columns past the status line, so the closing corner clears the final "]"
  # of the key hint instead of sitting flush against it.
  HDR_OVERHANG=2
  # Clamp to the terminal so the pause badge, which sits outside the box, cannot
  # push the header past the right edge on a narrow window.
  hdr_target=$(( ${#line2_plain} + HDR_OVERHANG ))
  max_target=$(( TERM_COLS - ${#hdr_plain} ))
  [ "$hdr_target" -gt "$max_target" ] && hdr_target="$max_target"
  rule_w=$(( hdr_target - ${#hdr_title} - 1 ))
  [ "$rule_w" -lt 3 ] && rule_w=3
  printf -v hdr_rule '%*s' "$rule_w" ''
  hdr_rule="${hdr_rule// /─}"

  emit '%s%s%s┐%s%s\n' "$C_HDR" "$hdr_title" "$hdr_rule" "$C_RST" "$hdr_state"
  emit '  %s%s   every %ss%s   %s%s%s%s\n\n' \
       "$C_DIM" "$stamp" "$INTERVAL" "$C_RST" "$C_DIM" "$keyhint" "$C_RST" "$off"

  if [ "$SHOW_HELP" = "1" ]; then
    help_overlay
    OUT+=$'\n'
  fi

  if [ "$PAUSED" = "0" ] || [ "$FIRST" = "1" ]; then
    # render_host appends to OUT directly and mutates the detector state, so it
    # must run in THIS shell. The body is sliced back out afterwards so a paused
    # frame can be redrawn without polling.
    mark="${#OUT}"
    for H in $HOSTS; do
      render_host "$H"
      OUT+=$'\n'
    done
    LAST_BODY="${OUT:$mark}"
    FIRST=0
  else
    OUT+="${LAST_BODY:-}"
  fi

  drain_probe_log
  maybe_auto_scan

  if [ "$SHOW_EVENTS" = "1" ] && [ "${#EVENTS[@]}" -gt 0 ]; then
    emit '  %sEVENTS%s %s(last %s)%s\n' "$C_HDR" "$C_RST" "$C_DIM" "$EVENT_MAX" "$C_RST"
    for ev in "${EVENTS[@]}"; do
      ts="${ev%%|*}"; rest="${ev#*|}"; col="${rest%%|*}"; txt="${rest#*|}"
      emit '    %s%s%s %s%s%s\n' "$C_DIM" "$ts" "$C_RST" "$col" "$txt" "$C_RST"
    done
    OUT+=$'\n'
  fi


  # Frame painting. Two things are needed to stop the display corrupting, and the
  # first version had neither:
  #
  #   1. Every line must be terminated with \e[K (erase to end of line). Without it
  #      a short line leaves the tail of whatever longer line occupied that row in
  #      the previous frame -- which is what made the event list look overwritten,
  #      since event text varies in length frame to frame.
  #   2. The frame must not exceed the terminal height. If it does, the terminal
  #      scrolls, \e[H then no longer refers to the top of the frame, and every
  #      subsequent repaint lands one row off and smears.
  if [ -t 1 ]; then
    frame=$(printf '%s' "$OUT" | head -n $(( TERM_ROWS > 2 ? TERM_ROWS - 1 : 1 )) )
    nl_count=$(printf '%s\n' "$OUT" | wc -l)
    [ "$nl_count" -ge "$TERM_ROWS" ] && frame+=$'\n  \e[2m…frame clipped to terminal height\e[0m'
    printf '\e[H%s\e[J' "${frame//$'\n'/$'\e[K'$'\n'}"
  else
    printf '%s' "$OUT"
  fi

  # read doubles as the sleep, so keys stay responsive at any refresh rate.
  # A timeout returns non-zero; that is the normal path and must not abort.
  key=""
  if [ -t 0 ]; then
    read -rsn1 -t "$INTERVAL" key || true
  else
    sleep "$INTERVAL"
  fi

  case "$key" in
    # + and - act on the INTERVAL, matching btop: "+" makes the number bigger, so
    # the refresh gets slower. (The first version had these inverted.)
    +|=)  [ "$IDX" -lt $(( ${#INTERVALS[@]} - 1 )) ] && IDX=$((IDX+1)); save_config ;;
    -|_)  [ "$IDX" -gt 0 ] && IDX=$((IDX-1)); save_config ;;
    v|V)  SHOW_BARS=$((1-SHOW_BARS)); save_config ;;
    m|M)  SHOW_MODELS=$((1-SHOW_MODELS)); save_config ;;
    w|W)  SHOW_WARN=$((1-SHOW_WARN)); save_config ;;
    e|E)  SHOW_EVENTS=$((1-SHOW_EVENTS)); save_config ;;
    l|L)  cycle_event_max ;;
    p|P)  PAUSED=$((1-PAUSED)) ;;
    h|H|\?) SHOW_HELP=$((1-SHOW_HELP)) ;;
    t|T)  # cycle to the next theme and repaint on the next frame
          for i in "${!THEMES[@]}"; do
            if [ "${THEMES[$i]}" = "$THEME" ]; then
              THEME="${THEMES[$(( (i + 1) % ${#THEMES[@]} ))]}"
              break
            fi
          done
          apply_theme "$THEME"; save_config ;;
    s|S)  start_probe ;;
    d|D)  discover "$HOSTS" ;;
    q|Q)  cleanup 0 ;;
  esac
done
