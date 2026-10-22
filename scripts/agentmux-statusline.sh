#!/usr/bin/env bash
# AgentMux statusline for Claude Code.
#   1. Renders a compact, colored status line to stdout (shown in the CLI):
#      model (+ effort) | config dir | project | ctx bar | 5h bar | 7d bar
#   2. Atomically writes a generic, versioned JSON sidecar to
#      $AGENTMUX_STATUS_DIR so AgentMux (and any other tool) can read live
#      agent status over SSH WITHOUT parsing the transcript jsonl.
# Fed one JSON object on stdin by Claude Code. Must be fast and exit 0.
set -u

IN=$(cat)
STATUS_DIR="${AGENTMUX_STATUS_DIR:-$HOME/.agentmux/status}"

command -v jq >/dev/null 2>&1 || { printf 'claude\n'; exit 0; }

# Reshape stdin into AgentMux's canonical, versioned status object.
OBJ=$(printf '%s' "$IN" | jq -c '
  {
    schema: 1,
    updated_at: (now | floor),
    agent: "claude",
    session_id: (.session_id // null),
    tmux_pane: (env.TMUX_PANE // null),
    config_dir: (env.CLAUDE_CONFIG_DIR // null),
    cwd: (.cwd // .workspace.current_dir // null),
    project_dir: (.workspace.project_dir // .cwd // null),
    version: (.version // null),
    model: { id: (.model.id // null), name: (.model.display_name // null) },
    effort: (.effort.level // null),
    fast_mode: (.fast_mode // false),
    context: (if .context_window == null then null else {
        used_percentage: .context_window.used_percentage,
        remaining_percentage: .context_window.remaining_percentage,
        size: .context_window.context_window_size,
        input_tokens: (.context_window.current_usage.input_tokens // null),
        total_input_tokens: .context_window.total_input_tokens,
        total_output_tokens: .context_window.total_output_tokens
      } end),
    rate_limits: (.rate_limits // null)
  }' 2>/dev/null)

# Write the sidecar atomically, keyed by session_id (fallback: pane).
if [ -n "$OBJ" ]; then
  key=$(printf '%s' "$OBJ" | jq -r '(.session_id // .tmux_pane // "unknown") | gsub("[^A-Za-z0-9._%-]"; "_")' 2>/dev/null)
  if [ -n "$key" ]; then
    mkdir -p "$STATUS_DIR" 2>/dev/null
    tmp="$STATUS_DIR/.$key.$$.tmp"
    if printf '%s\n' "$OBJ" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$STATUS_DIR/$key.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
  fi
fi

# ---------- render the pretty status line ----------
[ -n "$OBJ" ] || { printf 'claude\n'; exit 0; }

IFS=$'\t' read -r MODEL EFFORT FAST CFG PROJ CTX FIVEH SEVEND R5 R7 <<EOF
$(printf '%s' "$OBJ" | jq -r '[
    (.model.name // .model.id // "claude"),
    (.effort // "-"),
    (if .fast_mode then "1" else "0" end),
    (.config_dir // "-"),
    (.project_dir // .cwd // "-"),
    (.context.used_percentage // -1 | floor | tostring),
    (.rate_limits.five_hour.used_percentage // -1 | floor | tostring),
    (.rate_limits.seven_day.used_percentage // -1 | floor | tostring),
    (.rate_limits.five_hour.resets_at // -1 | floor | tostring),
    (.rate_limits.seven_day.resets_at // -1 | floor | tostring)
  ] | @tsv' 2>/dev/null)
EOF

esc() { printf '\033[%sm' "$1"; }
fg() { printf '\033[38;2;%sm' "$1"; }   # 24-bit truecolor foreground
R=$(esc 0); DIM=$(esc 2); BOLD=$(esc 1)
# Muted, low-saturation palette (easy on the eye on a dark background).
C_MODEL=$(fg '124;163;179')   # soft teal
C_FAST=$(fg '170;138;180')    # soft mauve
C_OK=$(fg '116;194;124')      # muted green  (< 70%)
C_WARN=$(fg '200;168;104')    # muted amber  (70-90%)
C_HIGH=$(fg '203;118;110')    # muted red    (>= 90%)
C_TRACK=$(fg '92;96;104')     # dim gray (unfilled bar track)
SEP="${DIM} │ ${R}"
pct_color() { if [ "$1" -ge 90 ]; then printf '%s' "$C_HIGH"; elif [ "$1" -ge 70 ]; then printf '%s' "$C_WARN"; else printf '%s' "$C_OK"; fi; }
base() { b=${1##*/}; printf '%s' "${b:-$1}"; }
# Compact time until a limit resets ("2d5h", "3h12m", "45m"); empty if unknown.
fmt_reset() {
  [ "${1:--1}" -ge 0 ] 2>/dev/null || return 0
  r=$(( $1 - $(date +%s) )); [ "$r" -gt 0 ] || return 0
  d=$((r / 86400)); h=$(( (r % 86400) / 3600 )); m=$(( (r % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

bar() { # $1=pct $2=width $3=fill-color -> colored filled blocks + dim track
  p=$1; w=$2; fc=$3; f=$(( (p * w + 50) / 100 ))
  [ "$f" -lt 0 ] && f=0; [ "$f" -gt "$w" ] && f=$w
  i=0; s="$fc"
  while [ "$i" -lt "$f" ]; do s="${s}█"; i=$((i + 1)); done
  s="${s}${C_TRACK}"
  while [ "$i" -lt "$w" ]; do s="${s}░"; i=$((i + 1)); done
  printf '%s%s' "$s" "$R"
}

CFGB=$(base "$CFG"); PROJB=$(base "$PROJ")
RST5=$(fmt_reset "$R5"); RST7=$(fmt_reset "$R7")

# Terminal width: Claude Code captures stdout (so tput/stty fail) but exports
# COLUMNS. Keep the rendered line within it so Claude Code never truncates us
# to "…". A margin absorbs any padding Claude Code adds on the left.
cols=${COLUMNS:-100}
budget=$(( cols - ${AGENTMUX_SL_MARGIN:-2} ))
[ "$budget" -lt 12 ] && budget=12

# Append one metric to OUT, tracking visible WIDTH. Each metric is set off by
# the same " │ " separator used between the other fields, so every ctx/5h/7d
# group stays visually distinct even when it collapses to a no-data "5h —"
# (with a plain space you can't tell which number belongs to which label).
# BARW (global, >= 0) is the bar length in columns; 0 means no bar. Every glyph
# we emit (ASCII, block bar, box-drawing) is exactly one terminal column.
addmetric() { # $1=label $2=pct $3=reset-suffix ; globals: BARW OUT WIDTH
  lbl=$1; p=$2; rst=${3:-}
  [ -n "$OUT" ] && { OUT="$OUT$SEP"; WIDTH=$((WIDTH + 3)); }
  if [ "${p:--1}" -ge 0 ] 2>/dev/null; then
    col=$(pct_color "$p")
    if [ "${BARW:-0}" -gt 0 ]; then
      OUT="$OUT${DIM}${lbl}${R} $(bar "$p" "$BARW" "$col") ${col}${p}%${R}"
      WIDTH=$((WIDTH + ${#lbl} + ${#p} + BARW + 3))
    else
      OUT="$OUT${DIM}${lbl}${R} ${col}${p}%${R}"
      WIDTH=$((WIDTH + ${#lbl} + ${#p} + 2))
    fi
    if [ -n "$rst" ]; then OUT="$OUT ${DIM}${rst}${R}"; WIDTH=$((WIDTH + 1 + ${#rst})); fi
  else
    OUT="$OUT${DIM}${lbl} —${R}"
    WIDTH=$((WIDTH + ${#lbl} + 2))
  fi
}

# Count metrics that will draw a bar (shown + numeric) at the current flags.
nbars() {
  n=0
  [ "$CTX_" = 1 ] && [ "${CTX:--1}" -ge 0 ] 2>/dev/null && n=$((n + 1))
  [ "${FIVEH:--1}" -ge 0 ] 2>/dev/null && n=$((n + 1))
  [ "${SEVEND:--1}" -ge 0 ] 2>/dev/null && n=$((n + 1))
  echo "$n"
}

# Build the line into OUT (+ visible WIDTH) at bar width BARW for one field set.
build() { # globals: BARW FAST_ EFFORT_ CFG_ PROJ_ CTX_ MODEL_
  OUT=""; WIDTH=0
  if [ "$MODEL_" = 1 ]; then OUT="${C_MODEL}${BOLD}${MODEL}${R}"; WIDTH=${#MODEL}; fi
  if [ "$EFFORT_" = 1 ] && [ "${EFFORT:--}" != "-" ]; then OUT="$OUT ${DIM}${EFFORT}${R}"; WIDTH=$((WIDTH + 1 + ${#EFFORT})); fi
  if [ "$FAST_" = 1 ] && [ "${FAST:-0}" = 1 ]; then OUT="$OUT ${C_FAST}fast${R}"; WIDTH=$((WIDTH + 5)); fi
  if [ "$CFG_" = 1 ] && [ "${CFG:--}" != "-" ]; then OUT="$OUT${SEP}${DIM}${CFGB}${R}"; WIDTH=$((WIDTH + 3 + ${#CFGB})); fi
  if [ "$PROJ_" = 1 ] && [ "${PROJ:--}" != "-" ]; then OUT="$OUT${SEP}${BOLD}${PROJB}${R}"; WIDTH=$((WIDTH + 3 + ${#PROJB})); fi
  [ "$CTX_" = 1 ] && addmetric ctx "$CTX"
  addmetric 5h "$FIVEH" "$RST5"
  addmetric 7d "$SEVEND" "$RST7"
}

# Fit strategy: keep every field and shrink the BARS first (adaptive length,
# capped at MAXBAR, floored at MINBAR). Only when a level's text alone (no bars)
# overflows do we drop the lowest-priority field and retry: in order fast,
# effort, project, config dir, ctx, model. The 5h/7d numbers always survive.
MAXBAR=10; MINBAR=2; chosen=0
for lvl in \
  "1 1 1 1 1 1" \
  "0 1 1 1 1 1" \
  "0 0 1 1 1 1" \
  "0 0 1 0 1 1" \
  "0 0 0 0 1 1" \
  "0 0 0 0 0 1" \
  "0 0 0 0 0 0"; do
  set -- $lvl
  FAST_=$1 EFFORT_=$2 CFG_=$3 PROJ_=$4 CTX_=$5 MODEL_=$6
  BARW=0; build                              # width of this field set, no bars
  [ "$WIDTH" -le "$budget" ] || continue     # text alone overflows -> drop a field
  n=$(nbars)
  if [ "$n" -gt 0 ]; then
    w=$(( (budget - WIDTH) / n - 1 ))
    [ "$w" -gt "$MAXBAR" ] && w=$MAXBAR
    if [ "$w" -ge "$MINBAR" ]; then BARW=$w; build; fi
  fi
  chosen=1; break
done
[ "$chosen" = 1 ] || build                   # nothing fit: emit poorest, no bars

printf '%s\n' "$OUT"
