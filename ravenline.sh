#!/usr/bin/env bash
# ravenline — a raven that watches your Claude Code session.
# MIT License, Copyright (c) 2026 Zelyvox

command -v jq >/dev/null 2>&1 || { printf 'ravenline: jq is required\n'; exit 0; }

model='?' ctx=0 effort='' think=false lim5=-1 lim7=-1 dir=. sid=none
# @sh quotes every value, so eval only ever sees plain assignments.
# tr strips the CR that Windows builds of jq append to each line.
eval "$(jq -r '
  @sh "model=\(.model.display_name // "?")",
  @sh "ctx=\(.context_window.used_percentage // 0 | floor)",
  @sh "effort=\(.effort.level // "")",
  @sh "think=\(.thinking.enabled // false)",
  @sh "lim5=\(.rate_limits.five_hour.used_percentage // -1 | floor)",
  @sh "lim7=\(.rate_limits.seven_day.used_percentage // -1 | floor)",
  @sh "dir=\(.workspace.current_dir // .cwd // ".")",
  @sh "sid=\(.session_id // "none")"
' 2>/dev/null | tr -d '\r')"

isnum() { [[ $1 =~ ^-?[0-9]+$ ]]; }
isnum "$ctx"   || ctx=0
isnum "$lim5"  || lim5=-1
isnum "$lim7"  || lim7=-1
now=$(date +%s 2>/dev/null); isnum "$now" || now=0
tick=${RL_TICK:-$now};        isnum "$tick" || tick=0

# ---- git, refreshed at most every 5s; the timestamp lives inside the cache ----
key=${sid//[^[:alnum:]]/}
# Without a session id there is no safe cache key; sessions would share one file.
if [[ -z $key || $sid == none ]]; then cache=/dev/null; else cache="${TMPDIR:-/tmp}/ravenline.$key"; fi
stamp=0 branch='' dirty=''
{ IFS=$'\t' read -r stamp branch dirty; } 2>/dev/null <"$cache"
isnum "$stamp" || stamp=0
if (( now - stamp >= 5 )); then
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\r')
  [[ $branch == HEAD ]] && branch=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null | tr -d '\r')
  dirty=''
  [[ -n $branch && -n $(git -C "$dir" status --porcelain 2>/dev/null | head -1) ]] && dirty='*'
  printf '%s\t%s\t%s\n' "$now" "$branch" "$dirty" >"$cache" 2>/dev/null
fi

# ---- palette, taken from the Zelyvox raven: plum feathers, bronze clasp ----
e=$'\033['
if [[ -n ${NO_COLOR:-} ]]; then
  off='' bold='' dim='' plum='' bronze='' rust='' mist='' green='' yellow='' red=''
else
  off="${e}0m" bold="${e}1m" dim="${e}2m"
  plum="${e}38;5;140m" bronze="${e}38;5;179m" rust="${e}38;5;167m" mist="${e}38;5;183m"
  green="${e}32m" yellow="${e}33m" red="${e}31m"
fi

# ---- the raven ----
# ⟨ ⟩ folded wings, ▼ closed beak, ▽ open beak. Each render is a new process,
# so the frame is chosen from the clock; Claude Code re-renders it each tick.
frame() { local IFS='|' f; read -ra f <<<"$2"; bird=${f[$(( $1 % ${#f[@]} ))]}; }

tone=$plum
if (( ctx >= 90 )); then
  tone=$rust;   frame "$tick" '⟩◉▽◉⟨ !!|⟩◉▽◉⟨|⟨◉▽◉⟩ !!|⟩◉▽◉⟨'
elif (( ctx >= 75 )); then
  tone=$bronze; frame "$tick" '⟪°▼°⟫|⟪°▼°⟫ 🪶|⟪º▼º⟫|⟪°▼°⟫ 🪶'
elif [[ $effort == xhigh || $effort == max ]]; then
  tone=$bronze; frame "$tick" '⟨▸▼◂⟩ ⚡|⟨▸▼◂⟩|⟨▹▼◃⟩ ⚡|⟨▸▼◂⟩'
elif (( ctx >= 50 )); then
  frame "$tick" '⟨◐▼◐⟩|⟨◐▼◐⟩|⟨◒▼◒⟩|⟨◐▼◐⟩'
else
  phase=$(( tick % 15 ))
  if (( phase < 4 )); then
    stunts=(
      '⟨˘▼˘⟩ ☾|⟨˘▼˘⟩ ☾ ·|⟨˘▼˘⟩ ☾ · ·|⟨˘▼˘⟩ ☾'
      '⟨•▼•⟩|⟩•▼•⟨|⟨•▼•⟩|⟩˘▼˘⟨'
      '⟨•▼•⟩|⟨•▽•⟩ kraa|⟨•▽•⟩ kraa!|⟨˘▼˘⟩'
      '⟨•▼•⟩🪶|⟨˘▼˘⟩ 🪶|⟨•▼•⟩  🪶|⟨•▼•⟩'
      '⟨◔▼◔⟩ ✧|⟨◉▼◉⟩ ✦|⟨•▼•⟩🪙|⟨˘▼˘⟩🪙'
      '⟨•▼•⟩ 🔮|⟨◉▼◉⟩ 🔮|⟨•▼•⟩✧🔮|⟨˘▼˘⟩ 🔮'
      '⟨•▼•⟩|⟨•▼-⟩|⟨•▼•⟩|⟨-▼•⟩'
      '⟨•▼•⟩ ✶|⟨ᵔ▼ᵔ⟩ ✶|⟨ᵔ▼ᵔ⟩ ✶ ✶|⟨•▼•⟩'
      '⟨•▼•⟩|⟨•▼•⟩⟨•▼•⟩|⟨•▼•⟩⟨˘▼˘⟩|⟨•▼•⟩'
    )
    n=$(( tick / 15 % ${#stunts[@]} ))
    (( n == 5 )) && tone=$mist
    frame "$phase" "${stunts[n]}"
  else
    frame "$tick" '⟨•▼•⟩|⟨•▼•⟩|⟨•▼•⟩|⟨˘▼˘⟩|⟨•▼•⟩|⟨•▼•⟩|⟨◦▼◦⟩|⟨•▼•⟩'
  fi
fi

# ---- context gauge, 8 cells ----
if   (( ctx >= 80 )); then gtone=$red
elif (( ctx >= 50 )); then gtone=$yellow
else                       gtone=$green; fi
full=$(( ctx * 8 / 100 )); (( full > 8 )) && full=8; (( full < 0 )) && full=0
printf -v gauge '%*s' "$full" '';       gauge=${gauge// /▓}
printf -v rest  '%*s' $(( 8 - full )) ''; gauge+=${rest// /░}

limit() { # limit <label> <percent>; prints nothing when unknown
  (( $2 < 0 )) && return
  local t=$dim; (( $2 >= 80 )) && t=$rust
  printf '  %s%s%s %s%s%%%s' "$dim" "$1" "$off" "$t" "$2" "$off"
}

line1="${tone}${bird}${off}  ${bold}${model}${off}"
[[ -n $effort ]]     && line1+=" ${plum}effort${off} ${effort}"
[[ $think == true ]] && line1+=" ${plum}think${off}"
line1+="$(limit 5h "$lim5")$(limit 7d "$lim7")"

line2="${gtone}${gauge} ${ctx}%${off}"
if [[ -n $branch ]]; then
  (( ${#branch} > 22 )) && branch="${branch:0:21}…"
  line2+="  ${dim}⎇${off} ${branch}${dirty:+${bronze}${dirty}${off}}"
fi

printf '%s\n%s\n' "$line1" "$line2"
exit 0
