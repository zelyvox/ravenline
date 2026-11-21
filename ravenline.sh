#!/usr/bin/env bash
# ravenline — a raven that watches your Claude Code session.
# MIT License, Copyright (c) 2026 Zelyvox

(( BASH_VERSINFO[0] >= 4 )) || { printf 'ravenline: bash 4 or newer is required\n'; exit 0; }
command -v jq >/dev/null 2>&1 || { printf 'ravenline: jq is required\n'; exit 0; }

model='?' ctx=0 effort='' think=false fast=false lim5=-1 lim7=-1 r5=-1 r7=-1 dir=. sid=none
prnum='' prstate=''
# @sh quotes every value, so eval only ever sees plain assignments.
# tr strips the CR that Windows builds of jq append to each line.
eval "$(jq -r '
  @sh "model=\(.model.display_name // "?")",
  @sh "ctx=\(.context_window.used_percentage // 0 | floor)",
  @sh "effort=\(.effort.level // "")",
  @sh "think=\(.thinking.enabled // false)",
  @sh "fast=\(.fast_mode // false)",
  @sh "lim5=\(.rate_limits.five_hour.used_percentage // -1 | floor)",
  @sh "lim7=\(.rate_limits.seven_day.used_percentage // -1 | floor)",
  @sh "r5=\(.rate_limits.five_hour.resets_at // -1 | floor)",
  @sh "r7=\(.rate_limits.seven_day.resets_at // -1 | floor)",
  @sh "dir=\(.workspace.current_dir // .cwd // ".")",
  @sh "sid=\(.session_id // "none")",
  # pr is present only while the branch has an open pull request (or merge
  # request); review_state may be missing on its own.
  @sh "prnum=\(.pr.number // "")",
  @sh "prstate=\(.pr.review_state // "")",
  @sh "rl=\(.rate_limits // null | tojson)"
' 2>/dev/null | tr -d '\r')"

isnum() { [[ $1 =~ ^-?[0-9]+$ ]]; }
isnum "$ctx"   || ctx=0
isnum "$lim5"  || lim5=-1
isnum "$lim7"  || lim7=-1
isnum "$r5"    || r5=-1
isnum "$r7"    || r7=-1
isnum "$prnum" && (( prnum > 0 )) || prnum=''
now=$(date +%s 2>/dev/null); isnum "$now" || now=0
tick=${RL_TICK:-$now};        isnum "$tick" || tick=0

# ---- rate limits snapshot for other local tools; written only when known ----
if [[ -n ${rl:-} && $rl != null ]] && (( lim5 >= 0 )); then
  lf=${RAVENLINE_LIMITS_FILE:-$HOME/.claude/ravenline-limits.json}
  # Rewritten when the limits change or the stamp is a minute old, so an idle
  # session does not touch the disk every second.
  lf_old=''; { IFS= read -r lf_old; } 2>/dev/null <"$lf"
  lf_stamp=${lf_old#\{\"ts\":}; lf_stamp=${lf_stamp%%,*}; isnum "$lf_stamp" || lf_stamp=0
  if [[ ${lf_old#*,\"rate_limits\":} != "$rl}" ]] || (( now - lf_stamp >= 60 || now < lf_stamp )); then
    # 2>/dev/null first, so a missing directory is silent too.
    printf '{"ts":%s,"rate_limits":%s}\n' "$now" "$rl" 2>/dev/null >"$lf.tmp" && mv -f "$lf.tmp" "$lf" 2>/dev/null
  fi
fi

# ---- model-scoped weekly limits (e.g. Fable on Max) ----
# Claude Code does not hand these to status lines, so ravenline asks the usage
# endpoint itself: in the background, at most once per RAVENLINE_USAGE_TTL
# seconds, shared by all sessions (one claims a lock, the rest skip). The OAuth
# token goes to curl only on stdin (never argv, never disk), ~/.curlrc is
# ignored and redirects are not followed. Only model names and percentages are
# cached. A cache older than max(30 min, 2 x TTL) is unknown and not shown.
usage_fetch() {
  set -o pipefail
  local cf=${RAVENLINE_CREDENTIALS_FILE:-$HOME/.claude/.credentials.json} token='' exp='' rows
  command -v curl >/dev/null 2>&1 || return
  IFS=$'\t' read -r token exp < <(jq -r '.claudeAiOauth | [(.accessToken // "" | tostring),
    (.expiresAt // 0 | if type == "number" then floor else 0 end | tostring)] | @tsv' "$cf" 2>/dev/null | tr -d '\r')
  [[ -n $token ]] || return
  isnum "$exp" && (( exp > 0 && exp / 1000 < now )) && return
  rows=$(printf 'Authorization: Bearer %s\n' "$token" |
    curl -q -sf --max-time 10 --proto '=https' -H @- -H 'anthropic-beta: oauth-2025-04-20' \
      -H 'User-Agent: ravenline' https://api.anthropic.com/api/oauth/usage |
    jq -r '.limits[]? | select(type == "object" and .kind == "weekly_scoped") |
      ((try .scope.model.display_name catch null) // (try .scope.model.id catch null) // "scoped" |
        tostring | gsub("[^A-Za-z0-9._-]"; "") | .[0:12] | if . == "" then "scoped" else . end) as $n |
      (.percent | if type == "number" then floor else -1 end) as $p |
      select($p >= 0) | "\($n)\t\([$p, 100] | min)"' | tr -d '\r') || return
  token=''
  printf '%s\n%s\n' "$now" "$rows" 2>/dev/null >"$uf.tmp.$BASHPID" && mv -f "$uf.tmp.$BASHPID" "$uf" 2>/dev/null
}
scoped_limits=()
uf=${RAVENLINE_USAGE_FILE:-$HOME/.claude/ravenline-usage.tsv}
if [[ ${RAVENLINE_USAGE:-1} != 0 ]]; then
  uttl=${RAVENLINE_USAGE_TTL:-300}; isnum "$uttl" && (( uttl >= 60 && uttl <= 86400 )) || uttl=300
  ustale=$(( uttl * 2 > 1800 ? uttl * 2 : 1800 ))
  ustamp=0 utry=0 ulock=0
  if [[ -r $uf ]]; then
    { IFS= read -r ustamp
      while IFS=$'\t' read -r uname upct; do
        upct=${upct//$'\r'/}
        [[ $uname =~ ^[A-Za-z0-9._-]{1,12}$ ]] && isnum "$upct" && scoped_limits+=("${uname,,}" "$upct")
      done; } 2>/dev/null <"$uf"
    ustamp=${ustamp//$'\r'/}
  fi
  isnum "$ustamp" || ustamp=0
  (( now - ustamp > ustale || now < ustamp )) && scoped_limits=()
  { IFS= read -r utry; } 2>/dev/null <"$uf.try"
  utry=${utry//$'\r'/}; isnum "$utry" || utry=0
  if (( (now - ustamp >= uttl || now < ustamp) && (now - utry >= uttl || now < utry) )); then
    # A lock left by a killed fetch is cleared after two minutes.
    if [[ -e $uf.lock ]]; then
      { IFS= read -r ulock; } 2>/dev/null <"$uf.lock"
      ulock=${ulock//$'\r'/}; isnum "$ulock" || ulock=0
      (( now - ulock > 120 || now < ulock )) && rm -f -- "$uf.lock" 2>/dev/null
    fi
    # noclobber makes the claim atomic (O_EXCL); only the winner fetches.
    set -C
    if { printf '%s\n' "$now" >"$uf.lock"; } 2>/dev/null; then
      set +C
      if { printf '%s\n' "$now" >"$uf.try"; } 2>/dev/null; then
        ( usage_fetch; rm -f -- "$uf.lock" ) </dev/null >/dev/null 2>&1 &
      else
        rm -f -- "$uf.lock" 2>/dev/null
      fi
    fi
    set +C
  fi
fi

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

# ---- leftovers. Every five minutes, caches of sessions that ended over a day
# ago are removed, along with per-process temp files (ravenline.<key>.<pid>.<part>)
# that older versions' worker scan left behind. The sweep stays in the
# foreground, since a backgrounded find dies with the render. ----
sweep="${TMPDIR:-/tmp}/ravenline.sweep"
sweep_stamp=0; { IFS= read -r sweep_stamp; } 2>/dev/null <"$sweep"
sweep_stamp=${sweep_stamp//$'\r'/}; isnum "$sweep_stamp" || sweep_stamp=0
if (( now - sweep_stamp >= 300 || now < sweep_stamp )) && printf '%s\n' "$now" >"$sweep" 2>/dev/null; then
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'ravenline.*' \( -mmin +1440 -o -mmin +10 \( \
      -name '*.[0-9]*.stat' -o -name '*.[0-9]*.head' -o -name '*.[0-9]*.tail' -o -name '*.[0-9]*.out' \) \) \
    -delete </dev/null >/dev/null 2>&1
fi

# ---- palette, taken from the Zelyvox raven: plum feathers, bronze clasp ----
e=$'\033['
if [[ -n ${NO_COLOR:-} ]]; then
  off='' bold='' dim='' plum='' bronze='' rust='' mist='' violet='' green='' yellow='' red=''
else
  off="${e}0m" bold="${e}1m" dim="${e}2m"
  plum="${e}38;5;140m" bronze="${e}38;5;179m" rust="${e}38;5;167m" mist="${e}38;5;183m" violet="${e}38;5;135m"
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

limit() { # limit <label> <percent> [tone] [resets_at]; prints nothing when unknown
  (( $2 < 0 )) && return
  local l=${3:-$dim} t=${3:-$dim} left when=''; (( $2 >= 80 )) && t=$rust
  # Time until the window resets, in the two largest units that matter.
  if isnum "${4:-}" && (( $4 > now )); then
    left=$(( $4 - now ))
    if   (( left >= 86400 )); then printf -v when '%dd%dh' "$(( left / 86400 ))" "$(( left % 86400 / 3600 ))"
    elif (( left >= 3600 ));  then printf -v when '%dh%02dm' "$(( left / 3600 ))" "$(( left % 3600 / 60 ))"
    elif (( left >= 60 ));    then printf -v when '%dm' "$(( left / 60 ))"
    else                           when='<1m'; fi
    when=" ${dim}↻${when}${off}"
  fi
  printf '  %s%s%s %s%s%%%s%s' "$l" "$1" "$off" "$t" "$2" "$off" "$when"
}

line1="${tone}${bird}${off}  ${bold}${model}${off}"
[[ -n $effort ]]     && line1+=" ${plum}effort${off} ${effort}"
[[ $think == true ]] && line1+=" ${plum}think${off}"
[[ $fast == true ]]  && line1+=" ${bronze}fast${off}"
line1+="$(limit 5h "$lim5" '' "$r5")$(limit 7d "$lim7" '' "$r7")"
for (( i=0; i<${#scoped_limits[@]}; i+=2 )); do
  # Fable gets its own colour, so its weekly limit stands out from 5h / 7d.
  ltone=''; [[ ${scoped_limits[i]} == fable ]] && ltone=$violet
  line1+="$(limit "${scoped_limits[i]}" "${scoped_limits[i+1]}" "$ltone")"
done

line2="${gtone}${gauge} ${ctx}%${off}"
if [[ -n $branch ]]; then
  (( ${#branch} > 22 )) && branch="${branch:0:21}…"
  line2+="  ${dim}⎇${off} ${branch}${dirty:+${bronze}${dirty}${off}}"
fi
# The branch's open pull request and where its review stands.
if [[ -n $prnum ]]; then
  line2+="  ${dim}#${off}${prnum}"
  case $prstate in
    approved)          line2+=" ${green}approved${off}" ;;
    changes_requested) line2+=" ${rust}changes${off}" ;;
    draft|pending)     line2+=" ${dim}${prstate}${off}" ;;
  esac
fi

printf '%s\n%s\n' "$line1" "$line2"

exit 0
