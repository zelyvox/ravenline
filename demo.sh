#!/usr/bin/env bash
# demo.sh — show every raven mood; exits 1 if any render misbehaves.
#   bash demo.sh           moods and edge cases
#   bash demo.sh stunts    the nine idle stunts, frame by frame

cd "$(dirname "$0")" || exit 1
fail=0
tag="demo$$x"   # unique to this run, so cleanup never touches other files
# Keep the demo off the real session: no real agent logs, lanes or limits file.
sandbox=$(mktemp -d) || exit 1
trap 'rm -f "${TMPDIR:-/tmp}"/ravenline."$tag"*; rm -rf "$sandbox"' EXIT
export RAVENLINE_CLAUDE_DIR="$sandbox/claude" RAVENLINE_CODEX_DIR="$sandbox/codex"
export ZELYVOX_LANES_DIR="$sandbox/lanes" RAVENLINE_LIMITS_FILE="$sandbox/limits.json"

json() { # json <ctx> <effort>
  printf '{"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":%s},' "$1"
  printf '"effort":{"level":"%s"},"thinking":{"enabled":true},' "$2"
  printf '"rate_limits":{"five_hour":{"used_percentage":41},"seven_day":{"used_percentage":83}},'
  printf '"workspace":{"current_dir":"%s"},"session_id":"%s%s"}' "$PWD" "$tag" "$RANDOM"
}

run() { # run <label> <tick> <stdin> [VAR=value]
  local out rc
  out=$(printf '%s' "$3" | env RL_TICK="$2" ${4:+"$4"} bash ./ravenline.sh); rc=$?
  printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$out"
  if (( rc != 0 )) || [[ $(printf '%s\n' "$out" | wc -l) -ne 2 ]]; then
    echo "  FAIL: expected 2 lines, exit 0"; fail=1
  fi
}

if [[ ${1:-} == stunts ]]; then
  names=(roost stretch caw preen shiny omen wink stargaze huginn-muninn)
  for n in "${!names[@]}"; do
    printf '\n\033[1m%s\033[0m\n' "${names[n]}"
    for f in 0 1 2 3; do
      json 20 high | RL_TICK=$(( n * 15 + f )) bash ./ravenline.sh | head -1
    done
  done
  exit 0
fi

run "idle"                    5  "$(json 12 high)"
run "focused — 62%"           5  "$(json 62 high)"
run "locked in — xhigh"       5  "$(json 30 xhigh)"
run "ruffled — 78%"           5  "$(json 78 high)"
run "alarm — 94%"             5  "$(json 94 max)"
run "garbage input"           5  'not json'
run "empty input"             5  ''
run "NO_COLOR"                5  "$(json 40 high)" NO_COLOR=1

out=$(json 40 high | NO_COLOR=1 bash ./ravenline.sh)
[[ $out == *$'\033'* ]] && { echo "  FAIL: NO_COLOR still printed escapes"; fail=1; }

# Subagent rows: one still working, one that delivered its report through the
# SubagentHandback tool (no end_turn after it). Only the first may be listed.
transcript="$sandbox/session.jsonl"; subs="$sandbox/session/subagents"
mkdir -p "$subs"; : >"$transcript"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","name":"Bash"}]}}\n' "$ts" >"$subs/agent-live.jsonl"
printf '{"description":"working lane","model":"sonnet"}' >"$subs/agent-live.meta.json"
{ printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","name":"SubagentHandback"}]}}\n' "$ts"
  printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result"}]}}\n' "$ts"
} >"$subs/agent-done.jsonl"
printf '{"description":"finished lane","model":"sonnet"}' >"$subs/agent-done.meta.json"
out=$(json 40 high | sed "s|}\$|,\"transcript_path\":\"$transcript\"}|" | NO_COLOR=1 bash ./ravenline.sh)
printf '\n\033[1m%s\033[0m\n%s\n' "subagents" "$out"
[[ $out == *"working lane"* ]] || { echo "  FAIL: running subagent not listed"; fail=1; }
[[ $out == *"finished lane"* ]] && { echo "  FAIL: handed-back subagent still listed"; fail=1; }

echo
(( fail )) && echo "some checks failed" || echo "all checks passed"
exit "$fail"
