#!/usr/bin/env bash
#
# localPipeline.sh — the checks a developer should run before pushing.
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
# Modelled on the localPipeline.sh of myLastFmPlayer: numbered stages, one
# mark_result per stage, a summary table at the end, and a non-zero exit if any
# mandatory stage failed.
#
# Stages:
#   1. Tooling            — required and optional tools present
#   2. Syntax             — bash -n on every shell script
#   3. Shellcheck         — static analysis (mandatory when installed)
#   4. Executable bits    — scripts are chmod +x
#   5. Documentation      — README sections and licence present
#   6. Doc/code agreement — flags and keys in the README exist in the script
#   7. Help & arguments   — --help works, bad input exits 2
#   8. Robustness         — a corrupt config is ignored, not obeyed
#   9. Render smoke test  — a frame is produced without a server (offline)
#  10. Live smoke test    — optional, only if a real Ollama host answers
#
# Stage 10 is the only one that touches the network and it is never mandatory.
# Everything else runs fully offline.
#
# Usage:
#   ./localPipeline.sh                  # all stages
#   ./localPipeline.sh --no-live        # skip the live server check
#   ./localPipeline.sh --host 10.0.0.5  # host to use for stage 10
#   ./localPipeline.sh --report-dir DIR # keep logs (default: a temp dir, removed)
#   ./localPipeline.sh --help

set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${ROOT_DIR}/ollamaFarm.sh"
README="${ROOT_DIR}/README.md"
LICENSE="${ROOT_DIR}/LICENSE"

RUN_LIVE=true
LIVE_HOST=""
REPORT_DIR=""
REMOVE_REPORT_DIR=true

declare -a SUMMARY_LINES=()

TOOLING_OK=0
SYNTAX_OK=0
SHELLCHECK_OK=0
EXECBIT_OK=0
DOCS_OK=0
DOCAGREE_OK=0
HELP_OK=0
ROBUST_OK=0
RENDER_OK=0

C_RST=$'\e[0m'; C_B=$'\e[1m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RED=$'\e[31m'
[ -t 1 ] || { C_RST=""; C_B=""; C_GRN=""; C_YEL=""; C_RED=""; }

log()   { printf '%s==>%s %s\n' "$C_B" "$C_RST" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
error() { printf '%s[fail]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }

print_usage() {
  awk 'NR>1 { if ($0 !~ /^#/) exit; print }' "$0" \
    | sed '/^# Copyright (C)/,/^# this program\. If not, see/d' \
    | sed 's/^#$//; s/^# \{0,1\}//' \
    | awk 'NF || p { print; p = NF }'
}

mark_result() {
  local label="$1" status="$2" details="${3:-}"
  local colour="$C_GRN"
  case "$status" in
    FAIL) colour="$C_RED" ;;
    WARN|SKIP) colour="$C_YEL" ;;
  esac
  SUMMARY_LINES+=("$(printf '%-22s : %s%-4s%s %s' "$label" "$colour" "$status" "$C_RST" "$details")")
}

print_summary() {
  printf '\n%s========== localPipeline summary ==========%s\n' "$C_B" "$C_RST"
  local line
  for line in "${SUMMARY_LINES[@]}"; do printf '%s\n' "$line"; done
  printf '%s==========================================%s\n' "$C_B" "$C_RST"
  [ -n "$REPORT_DIR" ] && [ "$REMOVE_REPORT_DIR" = false ] && printf 'logs: %s\n' "$REPORT_DIR"
  return 0
}

# ------------------------------------------------------------------ stages ----

# All shell scripts in the repo, so a new one is covered without editing this file.
shell_scripts() {
  find "$ROOT_DIR" -maxdepth 1 -name '*.sh' -type f | sort
}

stage_tooling() {
  local missing="" optional_missing=""
  for t in bash curl jq awk sed find; do
    command -v "$t" >/dev/null || missing+="$t "
  done
  for t in shellcheck script stty; do
    command -v "$t" >/dev/null || optional_missing+="$t "
  done
  if [ -n "$missing" ]; then
    mark_result "1 Tooling" FAIL "missing required: ${missing% }"
    return 1
  fi
  if [ -n "$optional_missing" ]; then
    mark_result "1 Tooling" WARN "optional absent: ${optional_missing% }"
  else
    mark_result "1 Tooling" PASS "all required and optional tools present"
  fi
  return 0
}

stage_syntax() {
  local bad="" f
  while IFS= read -r f; do
    bash -n "$f" 2>>"$REPORT_DIR/syntax.log" || bad+="$(basename "$f") "
  done < <(shell_scripts)
  if [ -n "$bad" ]; then
    mark_result "2 Syntax" FAIL "bash -n failed: ${bad% }"
    return 1
  fi
  mark_result "2 Syntax" PASS "bash -n clean on $(shell_scripts | wc -l) script(s)"
  return 0
}

stage_shellcheck() {
  if ! command -v shellcheck >/dev/null; then
    # Not installed is a SKIP, not a pass: the check genuinely did not happen.
    mark_result "3 Shellcheck" SKIP "shellcheck not installed"
    return 0
  fi
  local bad="" f
  while IFS= read -r f; do
    shellcheck -S warning "$f" >>"$REPORT_DIR/shellcheck.log" 2>&1 || bad+="$(basename "$f") "
  done < <(shell_scripts)
  if [ -n "$bad" ]; then
    mark_result "3 Shellcheck" FAIL "warnings in: ${bad% } (see shellcheck.log)"
    return 1
  fi
  mark_result "3 Shellcheck" PASS "-S warning clean"
  return 0
}

stage_execbit() {
  local bad="" f
  while IFS= read -r f; do
    [ -x "$f" ] || bad+="$(basename "$f") "
  done < <(shell_scripts)
  if [ -n "$bad" ]; then
    mark_result "4 Executable bits" FAIL "not executable: ${bad% }"
    return 1
  fi
  mark_result "4 Executable bits" PASS "all scripts are +x"
  return 0
}

stage_docs() {
  local missing=""
  [ -s "$README" ]  || missing+="README.md "
  [ -s "$LICENSE" ] || missing+="LICENSE "
  if [ -n "$missing" ]; then
    mark_result "5 Documentation" FAIL "missing: ${missing% }"
    return 1
  fi
  local secs=("## What it watches" "## At runtime" "## Keys" "## Command line"
              "## Host discovery" "## Configuration" "## License")
  local s
  for s in "${secs[@]}"; do
    grep -qF "$s" "$README" || missing+="'$s' "
  done
  grep -q "Version 3, 29 June 2007" "$LICENSE" || missing+="GPLv3-text "
  grep -q "GNU General Public License" "$SCRIPT" || missing+="licence-header-in-script "
  if [ -n "$missing" ]; then
    mark_result "5 Documentation" FAIL "absent: ${missing% }"
    return 1
  fi
  mark_result "5 Documentation" PASS "README sections, LICENSE and script header present"
  return 0
}

stage_doc_agreement() {
  # The README is only useful if what it documents actually exists. This caught
  # real drift during development, so it is a mandatory stage rather than a lint.
  local problems=""

  # Long/short flags named in the README must appear in the script's argument
  # parser. Matched with bash string containment rather than grep: a leading "-"
  # makes grep treat the pattern as an option, and escaping it emits "stray \
  # before -" warnings that clutter the pipeline output.
  local caseblock readme_text f
  caseblock=$(awk '/^while \[ \$# -gt 0 \]/,/^done/' "$SCRIPT")
  readme_text=$(cat "$README")
  for f in -n -H -p -D --theme --probe-vram --no-auto-scan --no-color --version --help; do
    [[ "$readme_text" == *"$f"* ]] || continue
    [[ "$caseblock" == *"$f)"* || "$caseblock" == *"$f|"* ]] || problems+="$f "
  done

  # The interval ladder quoted in the README must match the array in the script.
  local ladder
  ladder=$(grep -oP '(?<=^INTERVALS=\().*(?=\))' "$SCRIPT")
  grep -qF "$ladder" "$README" || problems+="interval-ladder "

  # The version must be semver-shaped, agree with --version, and appear in the
  # README. Bumping it every commit is only useful if it cannot silently drift.
  local ver ver_flag
  ver=$(grep -oP '(?<=^VERSION=")[^"]+' "$SCRIPT")
  if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    problems+="version-not-semver($ver) "
  fi
  ver_flag=$("$SCRIPT" --version 2>/dev/null | awk '{print $2}')
  [ "$ver_flag" = "$ver" ] || problems+="version-flag-mismatch($ver_flag) "
  [[ "$readme_text" == *"$ver"* ]] || problems+="version-absent-from-README "

  # Config keys written must be the same set the README documents.
  local k
  for k in idx show_bars show_models show_warn show_events theme; do
    grep -qF "$k" "$README" || problems+="cfg:$k "
    grep -qF "$k" "$SCRIPT" || problems+="cfg:$k(script) "
  done

  if [ -n "$problems" ]; then
    mark_result "6 Doc/code agreement" FAIL "${problems% }"
    return 1
  fi
  mark_result "6 Doc/code agreement" PASS "flags, ladder and config keys agree"
  return 0
}

stage_help_and_args() {
  local problems="" out rc

  out=$("$SCRIPT" --help 2>&1); rc=$?
  printf '%s\n' "$out" > "$REPORT_DIR/help.txt"
  [ "$rc" -eq 0 ] || problems+="help-exit=$rc "
  printf '%s' "$out" | grep -q "Usage:" || problems+="help-missing-usage "
  # The licence block and shell code must not leak into the help text.
  printf '%s' "$out" | grep -q "WARRANTY" && problems+="help-leaks-licence "
  printf '%s' "$out" | grep -q "set -uo pipefail" && problems+="help-leaks-code "

  "$SCRIPT" --definitely-not-a-flag >/dev/null 2>&1; [ "$?" -eq 2 ] || problems+="bad-flag-not-2 "
  "$SCRIPT" -p abc >/dev/null 2>&1;                  [ "$?" -eq 2 ] || problems+="bad-port-not-2 "
  "$SCRIPT" -n >/dev/null 2>&1;                      [ "$?" -eq 2 ] || problems+="missing-value-not-2 "

  if [ -n "$problems" ]; then
    mark_result "7 Help & arguments" FAIL "${problems% }"
    return 1
  fi
  mark_result "7 Help & arguments" PASS "--help ok; bad input exits 2"
  return 0
}

stage_robustness() {
  # A hand-edited or corrupt config must be ignored, never executed. Uses an
  # isolated XDG_CONFIG_HOME so the developer's own settings are untouched.
  local tmp_cfg problems="" canary
  tmp_cfg=$(mktemp -d) || { mark_result "8 Robustness" FAIL "mktemp failed"; return 1; }
  canary="$tmp_cfg/canary"
  mkdir -p "$tmp_cfg/ollamafarm"
  {
    printf 'idx=999\n'
    printf 'show_bars=hax\n'
    printf 'show_models=$(touch %s)\n' "$canary"
    printf '`touch %s.bt`\n' "$canary"
    printf 'not_a_key=1\n'
  } > "$tmp_cfg/ollamafarm/config"

  local out
  out=$(XDG_CONFIG_HOME="$tmp_cfg" timeout 6 "$SCRIPT" -n 1 -H 127.0.0.1 --no-color </dev/null 2>&1)
  printf '%s\n' "$out" > "$REPORT_DIR/robustness.txt"

  [ -e "$canary" ] || [ -e "$canary.bt" ] && problems+="config-injection "
  # idx=999 is out of range and must be rejected, leaving the 1 s default.
  printf '%s' "$out" | grep -q "every 1s" || problems+="bad-idx-not-rejected "

  rm -rf "$tmp_cfg"
  if [ -n "$problems" ]; then
    mark_result "8 Robustness" FAIL "${problems% }"
    return 1
  fi
  mark_result "8 Robustness" PASS "corrupt config ignored, no injection"
  return 0
}

stage_render_offline() {
  # 127.0.0.1 almost certainly has no Ollama, which is the point: the monitor must
  # still paint a frame and report the host as unreachable rather than hang or die.
  local out
  out=$(timeout 8 "$SCRIPT" -n 1 -H 127.0.0.1 --no-color </dev/null 2>&1)
  printf '%s\n' "$out" > "$REPORT_DIR/render.txt"
  if ! printf '%s' "$out" | grep -q "Ollama farm"; then
    mark_result "9 Render smoke test" FAIL "no frame produced (see render.txt)"
    return 1
  fi
  if ! printf '%s' "$out" | grep -qE "UNREACHABLE|ollama "; then
    mark_result "9 Render smoke test" FAIL "host line missing from frame"
    return 1
  fi
  mark_result "9 Render smoke test" PASS "frame rendered; unreachable host handled"
  return 0
}

stage_live() {
  if [ "$RUN_LIVE" = false ]; then
    mark_result "10 Live smoke test" SKIP "suppressed by --no-live"
    return 0
  fi
  local hosts="$LIVE_HOST"
  if [ -z "$hosts" ]; then
    # Fall back to the script's own defaults so this needs no configuration.
    hosts=$(grep -oP '(?<=^DEFAULT_HOSTS=").*(?=")' "$SCRIPT")
  fi
  local h found=""
  for h in $hosts; do
    if curl -s --max-time 2 "http://$h:11434/api/version" | grep -q version; then
      found="$h"; break
    fi
  done
  if [ -z "$found" ]; then
    mark_result "10 Live smoke test" SKIP "no Ollama host answered (${hosts// /, })"
    return 0
  fi
  local out
  out=$(timeout 10 "$SCRIPT" -n 1 -H "$found" --no-color </dev/null 2>&1)
  printf '%s\n' "$out" > "$REPORT_DIR/live.txt"
  if printf '%s' "$out" | grep -qE "ollama [0-9]+\.[0-9]+"; then
    mark_result "10 Live smoke test" PASS "queried $found and read its version"
  else
    mark_result "10 Live smoke test" WARN "reached $found but no version parsed"
  fi
  return 0
}

# -------------------------------------------------------------------- main ----
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-live)    RUN_LIVE=false; shift ;;
      --host)       [ $# -ge 2 ] || { error "--host needs a value"; exit 2; }
                    LIVE_HOST="$2"; shift 2 ;;
      --report-dir) [ $# -ge 2 ] || { error "--report-dir needs a value"; exit 2; }
                    REPORT_DIR="$2"; REMOVE_REPORT_DIR=false; shift 2 ;;
      -h|--help)    print_usage; exit 0 ;;
      *) error "unknown argument: $1"; print_usage; exit 2 ;;
    esac
  done

  if [ -z "$REPORT_DIR" ]; then
    REPORT_DIR=$(mktemp -d) || { error "cannot create a log directory"; exit 1; }
  else
    mkdir -p "$REPORT_DIR" || { error "cannot create $REPORT_DIR"; exit 1; }
  fi
  trap '[ "$REMOVE_REPORT_DIR" = true ] && [ -n "$REPORT_DIR" ] && rm -rf "$REPORT_DIR"' EXIT

  [ -f "$SCRIPT" ] || { error "ollamaFarm.sh not found beside this script"; exit 1; }

  log "localPipeline for ollamaFarm — logs in $REPORT_DIR"

  log "1/10 tooling";            stage_tooling            && TOOLING_OK=1
  log "2/10 syntax";             stage_syntax             && SYNTAX_OK=1
  log "3/10 shellcheck";         stage_shellcheck         && SHELLCHECK_OK=1
  log "4/10 executable bits";    stage_execbit            && EXECBIT_OK=1
  log "5/10 documentation";      stage_docs               && DOCS_OK=1
  log "6/10 doc/code agreement"; stage_doc_agreement      && DOCAGREE_OK=1
  log "7/10 help & arguments";   stage_help_and_args      && HELP_OK=1
  log "8/10 robustness";         stage_robustness         && ROBUST_OK=1
  log "9/10 render smoke test";  stage_render_offline     && RENDER_OK=1
  log "10/10 live smoke test";   stage_live

  local exit_code=1
  if [ "$TOOLING_OK" -eq 1 ] && [ "$SYNTAX_OK" -eq 1 ] && [ "$SHELLCHECK_OK" -eq 1 ] \
     && [ "$EXECBIT_OK" -eq 1 ] && [ "$DOCS_OK" -eq 1 ] && [ "$DOCAGREE_OK" -eq 1 ] \
     && [ "$HELP_OK" -eq 1 ] && [ "$ROBUST_OK" -eq 1 ] && [ "$RENDER_OK" -eq 1 ]; then
    exit_code=0
  fi

  if [ "$exit_code" -eq 0 ]; then
    log "localPipeline.sh completed successfully"
  else
    error "localPipeline.sh completed with failing mandatory stage(s)"
  fi
  print_summary
  exit "$exit_code"
}

main "$@"
