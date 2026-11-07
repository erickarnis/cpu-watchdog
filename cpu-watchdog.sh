#!/bin/zsh
# cpu-watchdog — runs every 5 min via launchd (local.cpu-watchdog).
#
# Alerts (Ignore / Copy kill command / Kill — nothing is killed unless you click
# Kill) when:
#   1. a process averages more than CPU_THRESHOLD % CPU over STRIKES consecutive
#      checks (measured from cumulative CPU time, so it's a true average)
#   2. a dev server (node/bun/deno/python… running dev/serve/watch) has had no
#      parent process (reparented to launchd) for more than ORPHAN_HOURS
#
# Settings: defaults below, overridden by ~/.config/cpu-watchdog/config (zsh
# syntax, e.g. CPU_THRESHOLD=150), overridden by environment variables.

zmodload zsh/datetime

# --- settings ------------------------------------------------------------------
typeset -A _env
for _v in CPU_THRESHOLD STRIKES ORPHAN_HOURS REALERT_HOURS IDLE_MINUTES ALERT_TIMEOUT \
          INTERVAL STATE_DIR IGNORE_RE IGNORE_ARGS_RE DEV_BIN_RE DEV_ARGS_RE; do
  [[ -n ${(P)_v} ]] && _env[$_v]=${(P)_v}
done

CPU_THRESHOLD=80     # % of one core, averaged over a check interval (can exceed 100)
STRIKES=3            # consecutive high intervals before alerting (3 × 5 min = 15 min)
ORPHAN_HOURS=6       # how long an orphaned dev server may run
REALERT_HOURS=2      # alert again if still a problem this long after an alert (0 = never)
IDLE_MINUTES=2       # hold alerts while you've been away from the keyboard this long
ALERT_TIMEOUT=270    # seconds before an unanswered alert closes (left as a banner)
INTERVAL=300         # must match StartInterval in the launchd plist
STATE_DIR="$HOME/Library/Application Support/cpu-watchdog"
IGNORE_RE='^(kernel_task|WindowServer|mds_stores|mdworker_shared|backupd|softwareupdated)$'  # process names never flagged for CPU
IGNORE_ARGS_RE=''    # regex on full command line; matches are never flagged (either check)
DEV_BIN_RE='^(node|bun|deno|python[0-9.]*|ruby|php|hugo)$'
DEV_ARGS_RE='( dev| serve| watch| preview| start| run( |$)|vite|astro|next|webpack|nodemon|storybook|http\.server|runserver|uvicorn|gunicorn|--reload|jupyter)'

CONFIG=${CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/cpu-watchdog/config}
[[ -r $CONFIG ]] && source "$CONFIG"
for _v in ${(k)_env}; do typeset -g $_v=${_env[$_v]}; done

STATE="$STATE_DIR/state"
LOG="$STATE_DIR/watchdog.log"
mkdir -p "$STATE_DIR"
now=$EPOCHSECONDS
now_f=$EPOCHREALTIME   # sub-second precision for the CPU-average denominator

log()    { print -r -- "$(strftime '%F %T' $EPOCHSECONDS)  $*" >> "$LOG"; }
banner() {  # title message
  [[ -n $DRY_RUN ]] && { print -r -- "[banner] $1 — $2"; return; }
  osascript -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Funk"' \
    -e 'end run' "$1" "$2" >/dev/null 2>&1
}

# --- one snapshot of every process ---------------------------------------------
# key = pid:start-time, so a reused PID is never mistaken for the old process.
typeset -A KEY PPID_OF UID_OF CPU_S ETIME COMM
snapshot() {
  KEY=() PPID_OF=() UID_OF=() CPU_S=() ETIME=() COMM=()
  local pid ppid uid t etime w d mo y hms comm m s
  LC_ALL=C ps -Ao pid=,ppid=,uid=,time=,etime=,lstart=,comm= 2>/dev/null |
  while read -r pid ppid uid t etime w mo d hms y comm; do
    KEY[$pid]="$pid:$mo$d-$hms-$y"; PPID_OF[$pid]=$ppid; UID_OF[$pid]=$uid
    ETIME[$pid]=$etime; COMM[$pid]=${comm:t}
    # cumulative CPU time: [[dd-]hh:]mm:ss.cc  (macOS prints mmm:ss.cc)
    d=0; [[ $t == *-* ]] && { d=${t%%-*}; t=${t#*-}; }
    m=(${(s.:.)t}); s=${m[-1]}; m[-1]=()
    (( CPU_S[$pid] = d*86400 + (${#m} == 2 ? 10#${m[1]}*3600 + 10#${m[2]}*60 : 10#${m[1]}*60) + s ))
  done
}
snapshot

age_hours() {  # etime → whole hours in REPLY
  local e=$1 d=0 p; [[ $e == *-* ]] && { d=${e%%-*}; e=${e#*-}; }
  p=(${(s.:.)e}); REPLY=$(( d*24 + (${#p} == 3 ? 10#${p[1]} : 0) ))
}
fmt_age() { (( $1 >= 24 )) && REPLY="$(( $1 / 24 ))d $(( $1 % 24 ))h" || REPLY="${1}h"; }
args_of() { ps -o args= -p $1 2>/dev/null; }
cwd_of()  { lsof -a -p $1 -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }
desc_of() {  # short description: name plus a hint of its args
  local args=$(args_of $1) rest; [[ -z $args ]] && return 1
  rest=${args#* }; [[ $rest == $args ]] && rest=""
  local first=${rest%% *}  # node_modules/astro/bin/astro.mjs dev → astro.mjs dev
  rest=${first:t}${rest#$first}
  (( ${#rest} > 40 )) && rest="${${rest[1,40]}% *}…"
  REPLY="${COMM[$1]}${rest:+ ($rest)}"
}
tree_of() {  # pid and all its descendants (current snapshot), children last
  local -a out queue=($1) kids; local p c
  while (( $#queue )); do
    p=$queue[1]; queue[1]=(); out+=$p
    for c in ${(k)PPID_OF[(R)$p]}; do [[ ${PPID_OF[$c]} == $p ]] && queue+=$c; done
  done
  reply=($out)
}

# --- previous state ---------------------------------------------------------------
# line 1: "ts <epoch>"; then: key cpu_seconds strikes flags last_alert_epoch
typeset -A prev_cpu strikes flags last_alert
prev_ts=0
if [[ -r $STATE ]]; then
  while read -r k c n f a; do
    if [[ $k == ts ]]; then prev_ts=$c; continue; fi
    prev_cpu[$k]=$c; strikes[$k]=$n; flags[$k]=$f; last_alert[$k]=$a
  done < "$STATE"
fi
elapsed=$(( now_f - prev_ts ))
# first run, or the Mac slept through checks: just record a fresh baseline
fresh=$(( prev_ts == 0 || elapsed > INTERVAL * 5 / 2 ))

typeset -A new_strikes
for pid key in ${(kv)KEY}; do
  (( fresh )) && break
  [[ -n ${prev_cpu[$key]} ]] || continue
  (( (CPU_S[$pid] - prev_cpu[$key]) * 100.0 / elapsed >= CPU_THRESHOLD )) || continue
  [[ ${COMM[$pid]} =~ $IGNORE_RE ]] && continue
  new_strikes[$key]=$(( ${strikes[$key]:-0} + 1 ))
done

# --- decide what to report ------------------------------------------------------
idle=$(ioreg -c IOHIDSystem -d 4 -r -k HIDIdleTime 2>/dev/null | awk '/HIDIdleTime/{print int($NF/1e9); exit}')
away=$(( ${idle:-0} >= IDLE_MINUTES * 60 ))

due() {  # key flag-letter → true if not yet alerted, or due for a re-alert
  [[ ${flags[$1]} != *$2* ]] && return 0
  (( REALERT_HOURS > 0 && now - ${last_alert[$1]:-0} >= REALERT_HOURS * 3600 ))
}

typeset -a f_pid f_title f_detail f_flag
add_finding() {  # pid flag title detail
  [[ -n $IGNORE_ARGS_RE && " $(args_of $1) " =~ $IGNORE_ARGS_RE ]] && return
  f_pid+=$1; f_flag+=$2; f_title+=$3; f_detail+=$4
}

for pid key in ${(kv)KEY}; do
  # 1. sustained high CPU
  n=${new_strikes[$key]:-0}
  if (( n >= STRIKES )) && due $key c; then
    desc_of $pid || continue
    pct=$(( (CPU_S[$pid] - prev_cpu[$key]) * 100.0 / elapsed )); pct=${pct%.*}
    dur=$(( n * INTERVAL )); (( dur >= 60 )) && dur="$(( dur / 60 ))+ min" || dur="${dur}+ s"
    d="$pct% CPU for $dur · PID $pid"
    # every daemon's parent is launchd; only call dev tools "orphaned"
    [[ ${PPID_OF[$pid]} == 1 && ${COMM[$pid]} =~ $DEV_BIN_RE ]] && d+=" · orphaned"
    add_finding $pid c "Runaway process: $REPLY" "$d"
  fi
  # 2. orphaned dev server
  if [[ ${PPID_OF[$pid]} == 1 && ${COMM[$pid]} =~ $DEV_BIN_RE ]]; then
    age_hours ${ETIME[$pid]}; h=$REPLY
    (( h >= ORPHAN_HOURS )) && [[ " $(args_of $pid) " =~ $DEV_ARGS_RE ]] && due $key o || continue
    desc_of $pid || continue; ds=$REPLY
    fmt_age $h
    add_finding $pid o "Forgotten dev server: $ds" "Running $REPLY with no parent process · PID $pid"
  fi
done

# --- alert -----------------------------------------------------------------------
typeset -A out_flags out_alert
for k f in ${(kv)flags}; do out_flags[$k]=$f; out_alert[$k]=${last_alert[$k]}; done

if (( $#f_pid && ! away )); then
  mine=() theirs=() tilde='~'
  for i in {1..$#f_pid}; do
    p=$f_pid[i]; k=$KEY[$p]
    out_flags[$k]=${${out_flags[$k]:#-}//$f_flag[i]/}$f_flag[i]; out_alert[$k]=$now
    if [[ ${UID_OF[$p]} == $UID ]]; then
      mine+=$p; c=$(cwd_of $p); [[ -n $c ]] && f_detail[i]+=" · ${c/#$HOME/$tilde}"
    else
      theirs+=$p; f_detail[i]+=" · owned by $(id -un ${UID_OF[$p]} 2>/dev/null || print uid ${UID_OF[$p]}) (needs sudo)"
    fi
    log "$f_title[i] — $f_detail[i]"
  done

  if (( $#f_pid == 1 )); then
    title=$f_title[1]; msg=$f_detail[1]; killbtn="Kill"
  else
    title="$#f_pid processes need attention"; msg=""
    for i in {1..$(( $#f_pid < 6 ? $#f_pid : 6 ))}; do msg+="• ${f_title[i]#*: } — ${f_detail[i]}"$'\n\n'; done
    (( $#f_pid > 6 )) && msg+="…and $(( $#f_pid - 6 )) more (see watchdog.log)"
    msg=${msg%$'\n\n'}; killbtn="Kill all"
  fi
  (( $#theirs && ! $#mine )) && killbtn=""
  (( $#theirs && $#mine )) && killbtn="Kill mine"

  copy=""
  (( $#mine ))   && { tree=(); for p in $mine; do tree_of $p; tree+=($reply); done
                      copy="kill ${(u)tree}; sleep 3; kill -9 ${(u)tree} 2>/dev/null"; }
  (( $#theirs )) && copy+="${copy:+; }sudo kill ${theirs}"

  buttons='{"Ignore", "Copy kill command"'; [[ -n $killbtn ]] && buttons+=", \"$killbtn\""; buttons+='}'

  (
    if [[ -n $DRY_RUN ]]; then   # print instead of showing; DRY_RUN=<button> simulates a click
      print -r -- "[alert] $title"$'\n'"$msg"$'\n'"[buttons] $buttons"$'\n'"[copy] $copy"
      res="button returned:${DRY_RUN:#1}, gave up:false"
    else
      res=$(osascript -e 'on run argv' \
        -e "display alert (item 1 of argv) message (item 2 of argv) as warning buttons $buttons default button \"Ignore\" cancel button \"Ignore\" giving up after (item 3 of argv as integer)" \
        -e 'end run' "$title" "$msg" "$ALERT_TIMEOUT" 2>/dev/null)
    fi
    case $res in
      *"gave up:true"*)
        banner "$title" "Alert timed out. Still running: PID ${f_pid}. See watchdog.log."
        log "alert timed out; left a banner" ;;
      "")  # Ignore is the cancel button: osascript exits with an error, no output
        log "ignored" ;;
      *"button returned:Copy kill command,"*)
        [[ -n $DRY_RUN ]] || print -rn -- "$copy" | pbcopy
        banner "Copied to clipboard" "$copy"; log "copied: $copy" ;;
      *"button returned:Kill"*)
        typeset -A KEY_THEN; KEY_THEN=("${(@kv)KEY}")
        snapshot   # fresh view: skip anything that exited or whose PID was reused
        targets=()
        for p in $mine; do
          [[ ${KEY[$p]} == ${KEY_THEN[$p]} ]] || { log "skip PID $p: exited or reused"; continue; }
          tree_of $p; targets+=($reply)
        done
        targets=(${(u)targets})
        (( $#targets )) || { banner "Nothing killed" "Those processes already exited."; exit; }
        kill $targets 2>/dev/null
        for _ in 1 2 3 4 5; do sleep 1; alive=(); for p in $targets; do kill -0 $p 2>/dev/null && alive+=$p; done; (( $#alive )) || break; done
        (( $#alive )) && { kill -9 $alive 2>/dev/null; sleep 1; }
        alive=(); for p in $targets; do kill -0 $p 2>/dev/null && alive+=$p; done
        if (( $#alive )); then
          banner "Couldn't kill PID $alive" "Try: sudo kill -9 $alive"; log "kill FAILED: $alive"
        else
          banner "Killed ${#targets} process$([[ $#targets == 1 ]] || print es)" "PID $targets"; log "killed: $targets"
        fi ;;
    esac
  ) &
fi

# --- save state atomically ----------------------------------------------------------
# keep: every live process's CPU time (baseline for next check), strikes, and
# alert flags. Dead processes drop out automatically.
{
  print -r -- "ts $now_f"
  for pid key in ${(kv)KEY}; do
    printf '%s %.2f %d %s %d\n' $key ${CPU_S[$pid]} ${new_strikes[$key]:-0} ${out_flags[$key]:--} ${out_alert[$key]:-0}
  done
} > "$STATE.tmp.$$" && mv -f "$STATE.tmp.$$" "$STATE"

[[ -f $LOG ]] && (( $(wc -l < "$LOG") > 500 )) && tail -300 "$LOG" > "$LOG.tmp.$$" && mv -f "$LOG.tmp.$$" "$LOG"
wait   # for an open alert
exit 0
