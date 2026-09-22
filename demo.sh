#!/usr/bin/env bash
# demo.sh — show every raven mood; exits 1 if any render misbehaves.
#   bash demo.sh           moods and edge cases
#   bash demo.sh stunts    the nine idle stunts, frame by frame

cd "$(dirname "$0")" || exit 1
fail=0
trap 'rm -f "${TMPDIR:-/tmp}"/ravenline.demo*' EXIT

json() { # json <ctx> <effort>
  printf '{"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":%s},' "$1"
  printf '"effort":{"level":"%s"},"thinking":{"enabled":true},' "$2"
  printf '"rate_limits":{"five_hour":{"used_percentage":41},"seven_day":{"used_percentage":83}},'
  printf '"workspace":{"current_dir":"%s"},"session_id":"demo%s"}' "$PWD" "$RANDOM"
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

echo
(( fail )) && echo "some checks failed" || echo "all checks passed"
exit "$fail"
