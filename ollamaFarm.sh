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
#   ./ollamaFarm.sh --theme light      # dark (default) | vivid | light
#   ./ollamaFarm.sh --no-color         # plain output (also honours NO_COLOR)
#   ./ollamaFarm.sh --version          # print the version and exit
#
# Settings (interval and toggles) persist to $XDG_CONFIG_HOME/ollamafarm/config,
# so the refresh rate you picked is still there next time.
#
# Scope: this monitor reads the Ollama HTTP API and nothing else. GPU temperature,
# utilisation, fan and power are therefore out of scope -- the API does not expose
# them, and reaching nvidia-smi on the hosts would need SSH access this tool does not
# assume it has. Everything shown is real API data.
#
# On discovery: hosts are found by probing /api/version across the /24. Usable
# VRAM is deliberately NOT probed — establishing it means pushing num_ctx until
# the model spills, which loads models and disturbs a shared server. Known
# ceilings are listed in VRAM_TOTAL below; discovered hosts show "?" and get no
# bar rather than a guessed one.

set -uo pipefail

# Semantic version of this script. Patch is bumped on every commit;
# it is rendered in the header so a screenshot identifies its build.
VERSION="0.0.25"

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
# works on any terminal; the other two assume 256-colour support.
THEMES=(dark vivid light)
THEME=dark
HOSTS_FROM_ARG=0

# Interval ladder, btop-style: + and - step through it rather than free-typing.
INTERVALS=(0.25 0.5 1 2 3 5 10 30)
IDX=2                      # -> 1 s
SHOW_BARS=1
SHOW_MODELS=1
SHOW_WARN=1
SHOW_EVENTS=1
PAUSED=0
SHOW_HELP=0

# Measured usable VRAM ceilings (see README.md). Used only to draw bars.
# Absent host => "?" and no bar; nothing here is inferred.
declare -A VRAM_TOTAL=( [192.168.100.37]=12.2 [192.168.100.67]=36.1 )

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
  local k v t
  while IFS='=' read -r k v; do
    case "$k" in
      idx)          [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -lt "${#INTERVALS[@]}" ] && IDX="$v" ;;
      show_bars)    [[ "$v" =~ ^[01]$ ]] && SHOW_BARS="$v" ;;
      show_models)  [[ "$v" =~ ^[01]$ ]] && SHOW_MODELS="$v" ;;
      show_warn)    [[ "$v" =~ ^[01]$ ]] && SHOW_WARN="$v" ;;
      show_events)  [[ "$v" =~ ^[01]$ ]] && SHOW_EVENTS="$v" ;;
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

# ------------------------------------------------------------------ colours ---
# Colour encodes STATE, never decoration: C_GRN = healthy/resident,
# C_RED = actively costing you performance now, C_YEL = about to change.
#
# A theme repaints those slots; it must never repurpose them. Whatever the palette,
# the green thing is fine and the red thing is costing you throughput -- otherwise
# the display stops being readable at a glance, which is the only reason it exists.
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
      C_FIG=$'\e[38;5;166m'     # burnt orange — figures
      C_MODEL=$'\e[38;5;90m'    # plum — model names
      C_HDR=$'\e[1;38;5;23m'    # deep teal — rules and section headings
      C_HOST=$'\e[1;38;5;236m'  # near-black, bold — host identity
      C_LBL=$'\e[38;5;24m'      # dark teal — field labels and units
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
# Three sources, in descending order of trust:
#   exact   - the VRAM_TOTAL table, or a user override; a figure someone stands behind
#   probed  - found by the "s" scan: the largest footprint that stayed fully resident
#   learned - observed passively: the largest fully-resident total ever seen
#
# probed and learned are both LOWER BOUNDS, never totals, and are shown with a "+".
# The distinction is load-bearing: a bar that silently means either "this is the
# capacity" or "it is at least this" would be worse than drawing no bar at all.
# See docs/vram-discovery.md for why a split event cannot be used as a measurement.
declare -A VRAM_LEARNED=()
declare -A VRAM_SOURCE=()

load_vram_cache() {
  [ -r "$CACHE_VRAM" ] || return 0
  local h g src ts
  while IFS=$'\t' read -r h g src ts; do
    [ -n "$h" ] || continue
    [[ "$g" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
    case "$src" in probed|learned) ;; *) continue ;; esac
    VRAM_LEARNED[$h]="$g"; VRAM_SOURCE[$h]="$src"
  done < "$CACHE_VRAM"
}

save_vram_cache() {
  mkdir -p "$CFG_DIR" 2>/dev/null || return 0
  local h
  : > "$CACHE_VRAM.tmp" 2>/dev/null || return 0
  for h in "${!VRAM_LEARNED[@]}"; do
    printf '%s\t%s\t%s\t%s\n' "$h" "${VRAM_LEARNED[$h]}" "${VRAM_SOURCE[$h]:-learned}" "$(date +%s)" \
      >> "$CACHE_VRAM.tmp"
  done
  mv -f "$CACHE_VRAM.tmp" "$CACHE_VRAM" 2>/dev/null
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
    [ "${VRAM_SOURCE[$host]:-}" = "probed" ] || VRAM_SOURCE[$host]="learned"
    save_vram_cache
    event "$C_DIM" "$host: ceiling at least $(printf '%.1f' "$gb") GB (observed fully resident)"
  fi
}

# Echoes "<gb> exact" | "<gb> lower" | "" (unknown)
ceiling_for() {
  local host="$1"
  if [ -n "${VRAM_TOTAL[$host]:-}" ]; then printf '%s exact' "${VRAM_TOTAL[$host]}"; return; fi
  if [ -n "${VRAM_LEARNED[$host]:-}" ]; then printf '%s lower' "${VRAM_LEARNED[$host]}"; return; fi
  printf ''
}

load_vram_cache

# ------------------------------------------------------------- event log ------
# Ring buffer of state changes. This is where eviction thrash becomes visible:
# a snapshot cannot show it, only a diff between consecutive polls can.
EVENT_MAX=6
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

  local total kind
  read -r total kind <<<"$(ceiling_for "$host")"
  total="${total:-}"; kind="${kind:-}"

  emit '  %s%-16s%s %sollama %-7s%s ' "$C_HOST" "$host" "$C_RST" "$C_LBL" "$ver" "$C_RST"
  if [ -n "$total" ]; then
    [ "$SHOW_BARS" = "1" ] && emit '%s ' "$(bar "$used" "$total" 22)"
    if [ "$kind" = "lower" ]; then
      # "+" marks a lower bound: at least this much fits, the true ceiling may be more
      emit '%s%5.1f%s/%s%s+%s GB ' "$C_FIG" "$used" "$C_RST" "$C_LBL" "$total" "$C_RST"
    else
      emit '%s%5.1f%s/%s GB ' "$C_FIG" "$used" "$C_RST" "$total"
    fi
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
  emit '    %ss%s    scan idle hosts for their VRAM ceiling (minutes on a large box)\n' \
    "$C_B" "$C_RST"
  emit '    %sh ?%s  close this help\n' "$C_B" "$C_RST"
  emit '  %sWatched failure modes: eviction thrash (~70 s reload), split placement\n' "$C_DIM"
  emit '  (5.3x slower), missing baked num_ctx (16k cap, tool calls die),\n'
  emit '  presence_penalty != 0 (~35%% slower). See README.md.%s\n' "$C_RST"
}

# --------------------------------------------------------------- VRAM probe ----
# Finds the largest footprint that stays FULLY RESIDENT on a host, by loading a model
# at escalating num_ctx. That figure is still a lower bound on capacity, but a much
# tighter one than passive observation usually reaches.
#
# Three rules make this safe to bind to a key on somebody else's server:
#   1. an idle host only. If anything is resident the host is skipped, loudly. Evicting
#      a colleague's model costs them a ~70 s reload, so the scan never does it.
#   2. keep_alive 0 on every load, so nothing is left behind.
#   3. it runs detached, and the UI keeps refreshing. A scan takes ~40-70 s on a small
#      box and several minutes on a large one, because reach requires a large model and
#      a 33 GB model alone takes ~70 s to load.
plog() {
  printf '%s\n' "$*" >> "$PROBE_LOG"
  [ "$PROBE_CLI" = "1" ] && printf '%s\n' "$*"
  return 0
}

# Load a model at a given num_ctx, then report "<size_vram_gb> <split:0|1>".
probe_load() {  # probe_load <host> <model> <ctx>
  local host="$1" model="$2" ctx="$3" base="http://$1:$PORT" r
  curl -s --max-time 900 -X POST "$base/api/generate" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$model" --argjson c "$ctx" \
          '{model:$m,keep_alive:"60s",options:{num_ctx:$c}}')" >/dev/null 2>&1
  r=$(curl -s --max-time 10 "$base/api/ps" 2>/dev/null \
      | jq -r '.models[0] | "\(.size_vram/1e9) \(if .size_vram < .size - 5e7 then 1 else 0 end)"' 2>/dev/null)
  curl -s --max-time 60 -X POST "$base/api/generate" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$model" '{model:$m,keep_alive:0}')" >/dev/null 2>&1
  [ -n "$r" ] && printf '%s' "$r" || printf '0 1'
}

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

  local best=0 tried=0 model
  for model in $models; do
    [ "$tried" -ge 3 ] && break
    tried=$((tried + 1))

    local maxctx
    maxctx=$(curl -s --max-time 10 -X POST "$base/api/show" -H 'Content-Type: application/json' \
             -d "$(jq -nc --arg m "$model" '{model:$m}')" 2>/dev/null \
             | jq -r '.model_info | to_entries | map(select(.key|endswith(".context_length"))) | .[0].value // 262144' 2>/dev/null)
    [[ "$maxctx" =~ ^[0-9]+$ ]] || maxctx=262144

    plog "probe $host: $model (max ctx $maxctx)"
    local lo=2048 hi="$maxctx" res vram split
    res=$(probe_load "$host" "$model" "$lo"); vram="${res%% *}"; split="${res##* }"
    if [ "$split" = "1" ]; then
      plog "  $model splits even at ctx $lo — too large, trying a smaller model"
      continue
    fi
    fgt "$vram" "$best" && best="$vram"
    plog "  ctx $lo: resident $(printf '%.2f' "$vram") GB"

    # Binary search the largest fully-resident num_ctx. Bounded at 7 loads.
    local i=0
    while [ "$i" -lt 7 ] && [ $(( hi - lo )) -gt 4096 ]; do
      i=$((i + 1))
      local mid=$(( (lo + hi) / 2 ))
      res=$(probe_load "$host" "$model" "$mid"); vram="${res%% *}"; split="${res##* }"
      if [ "$split" = "0" ]; then
        lo="$mid"; fgt "$vram" "$best" && best="$vram"
        plog "  ctx $mid: resident $(printf '%.2f' "$vram") GB"
      else
        hi="$mid"
        plog "  ctx $mid: SPLIT — ceiling is below this"
      fi
    done
    break
  done

  if fgt "$best" 0; then
    plog "RESULT $host $(printf '%.2f' "$best")"
    # Persist from the worker as well, so a standalone --probe-worker run is not lost
    # if no UI is watching. Read-modify-write, so a concurrently learned entry for a
    # different host survives.
    VRAM_LEARNED[$host]="$(printf '%.2f' "$best")"; VRAM_SOURCE[$host]=probed
    save_vram_cache
  else
    plog "SKIP $host — could not place any model fully in VRAM"
  fi
}

probe_worker() {
  load_vram_cache
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
  mkdir -p "$CFG_DIR" 2>/dev/null
  setsid nohup "$0" --probe-worker -H "$(echo "$targets" | tr ' ' ',')" -p "$PORT" \
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
# unknown or merely "learned". An exact table figure or an earlier probe is trusted and
# left alone, and each host is attempted once per session so a failure cannot loop.
declare -A AUTO_TRIED=()
maybe_auto_scan() {
  [ "$AUTO_SCAN" = "1" ] || return 0
  probe_running && return 0
  local h cand=""
  for h in $HOSTS; do
    [ -n "${AUTO_TRIED[$h]:-}" ] && continue
    [ -n "${VRAM_TOTAL[$h]:-}" ] && continue                 # exact figure, trusted
    [ "${VRAM_SOURCE[$h]:-}" = "probed" ] && continue         # already probed
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
  [ "$size" -le "$PROBE_OFFSET" ] && return 0
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      RESULT*) set -- $line
               VRAM_LEARNED[$2]="$3"; VRAM_SOURCE[$2]=probed; save_vram_cache
               event "$C_GRN" "$2: ceiling at least $3 GB (probed)" ;;
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
# every host busy, or no model would fit -- so a caller can tell.
if [ "$PROBE_CLI" = "1" ]; then
  probe_worker
  for h in $HOSTS; do
    [ "${VRAM_SOURCE[$h]:-}" = "probed" ] && exit 0
  done
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
  keyhint='[+ slower  - faster  v m w e  d s  p pause  h help  q quit]'
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
    emit '  %sEVENTS%s\n' "$C_HDR" "$C_RST"
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
