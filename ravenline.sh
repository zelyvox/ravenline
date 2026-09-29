#!/usr/bin/env bash
# ravenline — a raven that watches your Claude Code session.
# MIT License, Copyright (c) 2026 Zelyvox

command -v jq >/dev/null 2>&1 || { printf 'ravenline: jq is required\n'; exit 0; }

# Read lane metadata with bash builtins; lane event logs are not read here.
# Pass each as text so a partial/invalid JSON write only skips that lane.
lane_files=() lane_args=() lane_indices=() lane_texts=() lane_pids=()
lane_more=0 agent_lane_starts='[]'
for lane_file in "${ZELYVOX_LANES_DIR:-$HOME/.zelyvox/lanes}"/*/meta.json; do
  [[ -f $lane_file && -r $lane_file ]] || continue
  lane_raw=$(<"$lane_file")
  lane_args+=(--arg "lane_${#lane_files[@]}" "$lane_raw")
  lane_files+=("$lane_file")
done

model='?' ctx=0 effort='' think=false lim5=-1 lim7=-1 dir=. sid=none transcript=''
# @sh quotes every value, so eval only ever sees plain assignments.
# tr strips the CR that Windows builds of jq append to each line.
eval "$(jq -r "${lane_args[@]}" '
  # Remove terminal controls and keep titles on one line. Count non-Latin-1
  # characters as two columns conservatively (including emoji and CJK).
  def clean: tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; " ");
  def width: [explode[] | if . > 255 then 2 else 1 end] | add // 0;
  def clip($n):
    if width <= $n then . else
      (reduce explode[] as $c ({s: [], w: 0, stop: false};
        (if $c > 255 then 2 else 1 end) as $w |
        if .stop or .w + $w > $n - 2 then .stop = true
        else .s += [$c] | .w += $w end) | .s | implode) + "…"
    end;

  @sh "model=\(.model.display_name // "?")",
  @sh "ctx=\(.context_window.used_percentage // 0 | floor)",
  @sh "effort=\(.effort.level // "")",
  @sh "think=\(.thinking.enabled // false)",
  @sh "lim5=\(.rate_limits.five_hour.used_percentage // -1 | floor)",
  @sh "lim7=\(.rate_limits.seven_day.used_percentage // -1 | floor)",
  @sh "dir=\(.workspace.current_dir // .cwd // ".")",
  @sh "sid=\(.session_id // "none")",
  @sh "transcript=\(.transcript_path // "")",
  @sh "rl=\(.rate_limits // null | tojson)",
  ($ARGS.named | to_entries | map(
    .key as $key | (try (.value | fromjson) catch null) |
    select(type == "object") | select(.status == "running") |
    . + {idx: ($key | ltrimstr("lane_") | tonumber)} |
    .started = (if (.started | type) == "number" then .started else now end)
  ) | sort_by(.started, .idx)) as $lanes |
  @sh "agent_lane_starts=\([$lanes[].started] | tojson)",
  @sh "lane_more=\([$lanes | length - 9, 0] | max)",
  ($lanes[:9][] |
    ([0, (now - .started | floor)] | max) as $secs |
    "\($secs / 60 | floor)m\($secs % 60 | tostring | if length < 2 then "0" + . else . end)s" as $elapsed |
    "\(.model // "?" | clean | sub("^gpt-6-"; "") | clip(12))/\(.effort // "?" | clean | clip(8))" as $label |
    "\($label) · " as $prefix | " · \($elapsed)" as $suffix |
    (.title // .id // "Untitled" | clean | clip([2, 68 - 2 - ($prefix | width) - ($suffix | width)] | max)) as $title |
    @sh "lane_indices+=(\(.idx))",
    @sh "lane_texts+=(\($prefix + $title + $suffix))",
    @sh "lane_pids+=(\(if (.pid | type) == "number" then (.pid | floor) else 0 end))"
  )
' 2>/dev/null | tr -d '\r')"

isnum() { [[ $1 =~ ^-?[0-9]+$ ]]; }
isnum "$ctx"   || ctx=0
isnum "$lim5"  || lim5=-1
isnum "$lim7"  || lim7=-1
now=$(date +%s 2>/dev/null); isnum "$now" || now=0
tick=${RL_TICK:-$now};        isnum "$tick" || tick=0

# ---- rate limits snapshot for other local tools; written only when known ----
if [[ -n ${rl:-} && $rl != null ]] && (( lim5 >= 0 )); then
  lf=${RAVENLINE_LIMITS_FILE:-$HOME/.claude/ravenline-limits.json}
  # 2>/dev/null first, so a missing directory is silent too.
  printf '{"ts":%s,"rate_limits":%s}\n' "$now" "$rl" 2>/dev/null >"$lf.tmp" && mv -f "$lf.tmp" "$lf" 2>/dev/null
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

# ---- background Codex lanes: oldest first, up to the 12-line total ----
if (( ${#lane_indices[@]} )); then
  lane_activity=()
  for lane_index in "${lane_indices[@]}"; do
    lane_file=${lane_files[$lane_index]}
    lane_log=${lane_file%/*}/log.jsonl
    [[ -f $lane_log ]] && lane_activity+=("$lane_log") || lane_activity+=("$lane_file")
  done
  # One stat process for all displayed lanes. A missing file is unknown/stale.
  declare -A lane_mtimes=()
  while IFS= read -r lane_stat; do
    lane_stat=${lane_stat//$'\r'/}
    lane_mtimes[${lane_stat#*:}]=${lane_stat%%:*}
  done < <(stat -c '%Y:%n' -- "${lane_activity[@]}" 2>/dev/null)
  for (( i=0; i<${#lane_indices[@]}; i++ )); do
    lane_mtime=${lane_mtimes[${lane_activity[$i]}]:-0}
    lane_mtime=${lane_mtime//$'\r'/}
    isnum "$lane_mtime" || lane_mtime=0
    lane_stale=false
    (( now - lane_mtime > 1200 )) && lane_stale=true
    # tasklist costs ~120ms per PID here; use mtime on Windows. On Unix,
    # kill is a builtin. Older lanes without a PID remain supported.
    case $OSTYPE in
      msys*|cygwin*|win*) ;;
      *) if (( ${lane_pids[$i]:-0} > 0 )) && ! kill -0 "${lane_pids[$i]}" 2>/dev/null; then lane_stale=true; fi ;;
    esac
    if [[ $lane_stale == true ]]; then
      printf '%s? %s%s\n' "$dim" "${lane_texts[$i]}" "$off"
    else
      printf '%s⚙ %s%s\n' "$plum" "${lane_texts[$i]}" "$off"
    fi
  done
  (( lane_more > 0 )) && printf '%s+%s more%s\n' "$dim" "$lane_more" "$off"
fi
# ---- Discovered workers. Cache metadata and completion by mtime + size. ----
# No launcher/registry is needed. Cache hits use bash builtins only; scanning
# uses one stat, one batched head (new metadata), one batched tail (changed logs)
# and one jq. Files older than two hours are never opened.
agent_scan() {
  local base=$1 today yesterday p sig oldsig ready rest mt size count=0
  local cached_stamp cached_cols cached_lanes started kind label title state clipped
  local -a files=() heads=() tails=() meta_args=()
  local -A signatures=() readiness=() states=()
  local cd=${RAVENLINE_CLAUDE_DIR:-$HOME/.claude}
  local xd=${RAVENLINE_CODEX_DIR:-$HOME/.codex}
  local tp=${transcript//\\//}
  if [[ $tp == [A-Za-z]:/* ]]; then tp="/${tp:0:1}${tp:2}"; fi
  # UTC timestamps in the logs; directory names follow the local date.
  printf -v today '%(%Y/%m/%d)T' "$now"
  printf -v yesterday '%(%Y/%m/%d)T' "$((now-86400))"
  local had_nullglob=0
  shopt -q nullglob && had_nullglob=1
  shopt -s nullglob
  [[ -n $tp ]] && files+=("${tp%.jsonl}"/subagents/agent-*.jsonl)
  files+=("$cd"/projects/*/*.jsonl "$xd"/sessions/"$today"/rollout-*.jsonl "$xd"/sessions/"$yesterday"/rollout-*.jsonl)
  local tmp="$base.$BASHPID"
  # Cache publication is synchronous. Cleanup has no readers left and need not
  # delay the statusline (close its output descriptors before backgrounding).
  trap 'rm -f -- "$tmp.stat" "$tmp.head" "$tmp.tail" "$tmp.out" >/dev/null 2>&1 & ((had_nullglob)) || shopt -u nullglob; trap - RETURN' RETURN
  : >"$tmp.stat"; : >"$tmp.head"; : >"$tmp.tail"
  if [[ -r $base ]]; then
    IFS=$'\t' read -r cached_stamp cached_cols cached_lanes <"$base"
    while IFS=$'\t' read -r p oldsig ready started kind label title state clipped; do
      [[ $p == /* ]] || continue
      signatures["$p"]=$oldsig; readiness["$p"]=$ready; states["$p"]=$state
    done <"$base"
  fi
  if (( ${#files[@]} )); then
    while IFS= read -r rest; do
      mt=${rest%%:*}; rest=${rest#*:}; size=${rest%%:*}; p=${rest#*:}
      isnum "$mt" && isnum "$size" || continue
      (( now - mt <= 7200 )) || continue
      # Paths containing terminal controls cannot be represented by this cache.
      [[ $p != *[$'\t\r\n']* ]] || continue
      ((count+=1))
      sig="$mt:$size"
      # Interactive sources stay excluded even while they write new messages.
      [[ ${states[$p]:-} == skip ]] && sig=${signatures[$p]}
      printf '%s\t%s\n' "$p" "$sig" >>"$tmp.stat"
      if [[ ${signatures[$p]:-} != "$sig" ]]; then
        tails+=("$p")
        if [[ ${readiness[$p]:-0} != 1 ]]; then
          heads+=("$p")
          if [[ $p == */subagents/agent-*.jsonl && -r ${p%.jsonl}.meta.json ]]; then
            meta_args+=(--arg "meta:$p" "$(<"${p%.jsonl}.meta.json")")
          fi
        fi
      fi
    done < <(stat -c '%Y:%s:%n' -- "${files[@]}" 2>/dev/null)
  fi
  if [[ ! -s $tmp.stat ]]; then
    printf '%s\t%s\t%s\n' "$now" "$acols" "$agent_lane_starts" >"$tmp.out"
    mv -f -- "$tmp.out" "$base"
    return
  fi
  if (( ${#tails[@]} == 0 && count == ${#signatures[@]} )) &&
      [[ $cached_cols == "$acols" && $cached_lanes == "$agent_lane_starts" ]]; then
    { printf '%s\t%s\t%s\n' "$now" "$acols" "$agent_lane_starts"
      { IFS= read -r rest; while IFS= read -r rest; do printf '%s\n' "$rest"; done; } <"$base"
    } >"$tmp.out"
    mv -f -- "$tmp.out" "$base"
    return
  fi
  # Read new logs once, without an arbitrary line cutoff: the first real user
  # prompt can follow many environment messages. Ready logs only need tail.
  (( ${#heads[@]} )) && head -n -0 -v -- "${heads[@]}" >"$tmp.head" 2>/dev/null
  (( ${#tails[@]} )) && tail -n 3 -v -- "${tails[@]}" >"$tmp.tail" 2>/dev/null
  [[ -f $base ]] || printf '0\n' >"$base"
  jq -bnr --rawfile stats "$tmp.stat" --rawfile heads "$tmp.head" \
    --rawfile tails "$tmp.tail" --rawfile previous "$base" \
    --arg sid "$sid" --arg main "$model" --argjson now "$now" \
    --arg cols "$acols" --arg agent_starts "$agent_lane_starts" "${lane_args[@]}" "${meta_args[@]}" '
    def clean: tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; " ");
    def width: [explode[] | if . > 255 then 2 else 1 end] | add // 0;
    def clip($n): if width <= $n then . else
      (reduce explode[] as $c ({s:[],w:0,stop:false};
        (if $c > 255 then 2 else 1 end) as $w |
        if .stop or .w+$w > $n-2 then .stop=true
        else .s+=[$c] | .w+=$w end) | .s | implode)+"…" end;
    def epoch: try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch $now;
    # GNU head/tail headers retain filenames, including spaces. Malformed JSON
    # remains null, so a half-written last line cannot finish a subagent.
    def batches: reduce (split("\n")[]) as $s ({p:"",v:{}};
      ($s | rtrimstr("\r")) as $s |
      if ($s|startswith("==> ")) and ($s|endswith(" <==")) then
        .p=$s[4:-4] | .v[.p]=[]
      elif .p!="" and $s!="" then .v[.p]+=[try ($s|fromjson) catch null]
      else . end) | .v;
    ($heads|batches) as $h | ($tails|batches) as $t |
    (reduce ($previous|gsub("\r";"")|split("\n")[]|split("\t")|select(length==9)) as $r ({}; .[$r[0]]=$r)) as $old |
    [$ARGS.named|to_entries[]|select(.key|startswith("lane_"))|
      (try (.value|fromjson) catch null)|select(.status=="running")|.started|select(type=="number")] as $lanes |
    ([40, ([80, (try ($cols|tonumber) catch 80)]|min)]|max) as $cols |
    "\($now)\t\($cols)\t\($agent_starts)",
    ([$stats|split("\n")[]|split("\t")|select(length==2)|
      .[0] as $p | .[1] as $sig | ($old[$p]//[]) as $o |
      ($sig|split(":")[0]|tonumber) as $mtime |
      if $o[1]==$sig then $o else
        ($h[$p]//[]) as $events | ($t[$p]//[]) as $last |
        ($p|contains("/subagents/agent-")) as $sub |
        (if $sub then "sub" elif ($p|contains("/sessions/")) then "codex" else "sdk" end) as $kind |
        ($events|map(select(.type=="session_meta"))[0].payload//{}) as $meta |
        ($events|map(select(.type=="turn_context"))[0].payload//{}) as $ctx |
        ((try ($ARGS.named["meta:"+$p]|fromjson) catch null)//{}) as $sm |
        ($events|map(select(.type=="assistant"))[0].message.model//"") as $cm |
        (if $kind=="codex" then $meta.timestamp else $events[0].timestamp end) as $ts |
        (if $o[2]=="1" then $o[3]|tonumber else ($ts//""|epoch) end) as $start |
        (if $kind=="codex" then ($ctx.model//"?"|sub("^gpt-6-";""))+"/"+($ctx.collaboration_mode.settings.reasoning_effort//$ctx.reasoning_effort//"?")
         elif $sub then $sm.model//$main
         else $cm end | clean | sub("^claude-";"") | clip(24)) as $label |
        (if $sub then $sm.description//$sm.agentType//"Claude subagent"
         elif $kind=="codex" then
           [$events[]|select(.type=="response_item" and .payload.role=="user")|.payload.content[]?|
             select(.type=="input_text")|.text|select(type=="string")|select(startswith("<")|not)][0]
         else ([$events[]|select(.type=="queue-operation")|.content|select(type=="string")][0] //
           [$events[]|select(.type=="user")|.message.content|
             if type=="string" then . else [.[]?|select(.type=="text")|.text]|join(" ") end][0]) end) as $title |
        # A background subagent can also end by delivering its report through the
        # SubagentHandback tool: its last lines are that tool_use and its result,
        # with no end_turn after them. If it is resumed, new lines follow.
        (if $sub then ($last[-1].type=="assistant" and $last[-1].message.stop_reason=="end_turn") or
                           ($last[-1].type=="assistant" and $last[-1].stop_reason=="end_turn") or
                           ($last[-1].type=="user" and ($last|length)>=2 and $last[-2].type=="assistant" and
                            any($last[-2].message.content[]?; .type=="tool_use" and .name=="SubagentHandback"))
         elif $kind=="sdk" then any($last[]; .type=="cost-state" or .type=="last-prompt")
         else any($last[]; .type=="task_complete" or .type=="turn_aborted" or
                    .payload.type=="task_complete" or .payload.type=="turn_aborted") end) as $done |
        (if $o[2]=="1" then $o[7]=="skip"
         elif $kind=="codex" then ($meta.source!=null and $meta.source!="exec")
         elif $sub then false
         else (($p|endswith("/"+$sid+".jsonl")) or any($events[]; .entrypoint=="cli")) end) as $skip |
        (if $o[2]=="1" or $skip then "1"
         elif $kind=="codex" then (if $meta.source=="exec" and $ctx.model!=null and $title!=null then "1" else "0" end)
         elif $sub then (if $ts!=null and ($sm|length)>0 then "1" else "0" end)
         else (if any($events[];.entrypoint=="sdk-cli") and $cm!="" and $title!=null then "1" else "0" end) end) as $ready |
        [$p,$sig,$ready,($start|floor|tostring),$kind,
          (if $o[2]=="1" then $o[5] else if $label=="" then "?" else $label end end),
          (if $o[2]=="1" then $o[6] else ($title//"Working…"|clean|if .=="" then "Working…" else . end|clip(512)) end),
          (if $skip then "skip" elif $done then "done" else "active" end)]
      end |
      # Deduplication is recomputed each scan, even when a log is unchanged.
      if .[4]=="codex" and .[7]!="skip" and .[7]!="done" then
        (.[3]|tonumber) as $start |
        .[7]=(if any($lanes[]; (.-$start|fabs)<=60) then "lane" else "active" end)
      else . end] | sort_by(.[3]|tonumber)[] |
      .[5] |= clip([24,$cols-19]|min) |
      .[5] as $label | .[6] as $title |
      .[8]=($title|clip([2,$cols-($label|width)-17]|max)) | join("\t"))
  ' >"$tmp.out" 2>/dev/null && mv -f -- "$tmp.out" "$base"
}

if [[ -n $key && $sid != none ]]; then
  agent_cache="${TMPDIR:-/tmp}/ravenline.agents.$key"
  acols=${COLUMNS:-80}; isnum "$acols" || acols=80
  (( acols > 80 )) && acols=80; (( acols < 40 )) && acols=40
  agent_stamp=0 agent_cols=0
  { IFS=$'\t' read -r agent_stamp agent_cols agent_previous_lanes <"$agent_cache"; } 2>/dev/null
  agent_stamp=${agent_stamp//$'\r'/}
  isnum "$agent_stamp" || agent_stamp=0
  [[ $agent_cols == "$acols" ]] || agent_stamp=0
  if (( now - agent_stamp >= 2 || now < agent_stamp )); then
    agent_scan "$agent_cache" 2>/dev/null || exit 0
  fi
  agent_count=0 agent_total=0
  while IFS=$'\t' read -r ap asig ardy ast ak al at ad clipped; do
    ad=${ad//$'\r'/}
    [[ $ad == active && ( $ardy == 1 || $ak == sub ) ]] || continue
    amt=${asig%%:*}
    isnum "$amt" && isnum "$ast" || continue
    (( now - amt <= 7200 )) && (( ++agent_total ))
  done <"$agent_cache" 2>/dev/null
  agent_room=$(( 10 - ${#lane_indices[@]} ))
  (( lane_more > 0 )) && agent_room=0
  if (( agent_total > agent_room && agent_room > 0 )); then ((agent_room-=1)); fi
  while IFS=$'\t' read -r ap asig ardy ast ak al at ad clipped; do
    ad=${ad//$'\r'/}
    [[ $ad == active && ( $ardy == 1 || $ak == sub ) ]] || continue
    amt=${asig%%:*}
    isnum "$amt" && isnum "$ast" || continue
    (( now - amt <= 7200 )) || continue
    (( agent_count >= agent_room )) && continue
    (( ++agent_count ))
    asecs=$(( now - ast )); (( asecs < 0 )) && asecs=0
    if (( asecs >= 3600 )); then
      printf -v elapsed '%dh%02dm' "$((asecs/3600))" "$((asecs/60%60))"
    else
      printf -v elapsed '%dm%02ds' "$((asecs/60))" "$((asecs%60))"
    fi
    acolor=$plum; icon='✦'; [[ $ak == codex ]] && icon='⚙'
    if (( now - amt > 900 )); then acolor=$dim; icon='?'; fi
    at=$clipped
    printf '%s%s %s · %s · %s%s\n' "$acolor" "$icon" "$al" "$at" "$elapsed" "$off"
  done <"$agent_cache" 2>/dev/null
  agent_more=$(( agent_total - agent_count ))
  if (( agent_more > 0 && agent_room > 0 )); then
    printf '%s+%s more%s\n' "$dim" "$agent_more" "$off"
  fi
fi
exit 0
