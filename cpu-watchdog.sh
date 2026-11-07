#!/bin/zsh
# cpu-watchdog — runs every 5 min via launchd (local.cpu-watchdog).
# Shows an alert (Ignore / Copy kill command / Kill — nothing is killed unless
# you click Kill) when:
#   1. a process stays above CPU_THRESHOLD % for STRIKES consecutive checks
#   2. a dev server (node/bun/deno/python… running dev/serve/watch) has been
#      orphaned (parent = launchd) for more than ORPHAN_HOURS
# Each process is reported once per lifetime. Log: $STATE_DIR/watchdog.log

CPU_THRESHOLD=${CPU_THRESHOLD:-80}   # % of one core (top-style, can exceed 100)
STRIKES=${STRIKES:-3}                # consecutive high checks before alerting (3 × 5 min = 15 min)
ORPHAN_HOURS=${ORPHAN_HOURS:-6}
STATE_DIR=${STATE_DIR:-"$HOME/Library/Application Support/cpu-watchdog"}
IGNORE_RE='^(kernel_task|WindowServer|top|mds_stores|mdworker_shared)$'
DEV_BIN_RE='^(node|bun|deno|python[0-9.]*|ruby|php)$'
DEV_ARGS_RE='( dev| serve| watch| preview| start|vite|astro|next|webpack|nodemon|http\.server|runserver)'

STATE="$STATE_DIR/state"
LOG="$STATE_DIR/watchdog.log"
mkdir -p "$STATE_DIR"

typeset -A strikes flags new_strikes new_flags
if [[ -f $STATE ]]; then
  while read -r key count flag; do
    strikes[$key]=$count; flags[$key]=$flag
  done < "$STATE"
fi

log() { print -r -- "$(date '+%F %T')  $*" >> "$LOG"; }

banner() {  # title message — plain notification, no buttons
  osascript -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Funk"' \
    -e 'end run' "$1" "$2" >/dev/null 2>&1
}

# Alert window with Ignore / Copy kill command / Kill. Runs in the background so
# all checks finish first; the script waits for open alerts before exiting
# (launchd skips the next 5-min tick while one is still open — that's fine).
notify() {  # title message pid key
  local title=$1 msg=$2 pid=$3 key=$4
  log "$title — $msg"
  (
    res=$(osascript -e 'on run argv' \
      -e 'display alert (item 1 of argv) message (item 2 of argv) as warning buttons {"Ignore", "Copy kill command", "Kill"} default button "Ignore" cancel button "Ignore" giving up after 270' \
      -e 'end run' "$title" "$msg" 2>/dev/null)
    case $res in
      *"button returned:Kill,"*)
        # make sure the PID still belongs to the same process (no PID reuse)
        if [[ $(proc_key $pid) != $key ]]; then
          banner "Not killed" "PID $pid already exited or was reused."; log "kill skipped: PID $pid changed"; exit
        fi
        kill $pid 2>/dev/null
        for i in 1 2 3 4 5; do sleep 1; kill -0 $pid 2>/dev/null || break; done
        if kill -0 $pid 2>/dev/null; then kill -9 $pid 2>/dev/null; sleep 1; fi
        if kill -0 $pid 2>/dev/null; then
          banner "Couldn't kill PID $pid" "Try: sudo kill -9 $pid"; log "kill FAILED: PID $pid"
        else
          banner "Killed PID $pid" "$title"; log "killed PID $pid (user clicked Kill)"
        fi ;;
      *"button returned:Copy kill command,"*)
        print -rn -- "kill $pid || kill -9 $pid" | pbcopy
        banner "Copied to clipboard" "kill $pid || kill -9 $pid"; log "copied kill command for PID $pid" ;;
    esac
  ) &
}

proc_key()  { print -r -- "$1:$(ps -o lstart= -p $1 2>/dev/null | tr -d ' ')"; }
proc_cwd()  { lsof -a -p $1 -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }
proc_desc() {  # short human description: name plus a hint of its args
  local args=$(ps -o args= -p $1 2>/dev/null)
  local name=${${args%% *}:t}
  local rest=${args#* }; [[ $rest == $args ]] && rest=""
  # drop path noise from the first argument (e.g. node_modules/astro/bin/astro.mjs → astro.mjs)
  rest=$(print -r -- "$rest" | awk '{ n=split($1,p,"/"); $1=p[n]; print }')
  # shorten to ~40 chars at a word boundary
  if (( ${#rest} > 40 )); then rest=${rest[1,40]}; rest="${rest% *}…"; fi
  print -r -- "$name${rest:+ ($rest)}"
}

# --- 1. sustained high CPU ---------------------------------------------------
# Second top sample is a true 3-second measurement (the first is since-boot).
top -l 2 -s 3 -o cpu -n 15 -stats pid,cpu 2>/dev/null \
  | awk '/^PID/{n++; next} n==2 && NF==2 {print $1, $2}' \
  | while read -r pid cpu; do
      (( cpu >= CPU_THRESHOLD )) || continue
      comm=$(ps -o comm= -p $pid 2>/dev/null) || continue
      [[ ${comm:t} =~ $IGNORE_RE ]] && continue
      key=$(proc_key $pid)
      count=$(( ${strikes[$key]:-0} + 1 ))
      new_strikes[$key]=$count
      flag=${flags[$key]:--}
      if (( count >= STRIKES )) && [[ $flag != *c* ]]; then
        mins=$(( count * 5 ))
        orphan=""; [[ $(ps -o ppid= -p $pid | tr -d ' ') == 1 ]] && orphan=" · orphaned"
        notify "Runaway process: $(proc_desc $pid)" \
          "${cpu%.*}% CPU for ${mins}+ min · PID $pid$orphan · $(proc_cwd $pid)" $pid $key
        flag=${flag#-}c
      fi
      new_flags[$key]=$flag
    done

# --- 2. orphaned dev servers --------------------------------------------------
ps -Ao pid=,ppid=,etime=,comm= | while read -r pid ppid etime comm; do
  [[ $ppid == 1 && ${comm:t} =~ $DEV_BIN_RE ]] || continue
  # etime is [[dd-]hh:]mm:ss
  days=0; [[ $etime == *-* ]] && { days=${etime%%-*}; etime=${etime#*-}; }
  parts=(${(s.:.)etime}); hours=0; (( ${#parts} == 3 )) && hours=$(( 10#${parts[1]} ))
  (( days * 24 + hours >= ORPHAN_HOURS )) || continue
  [[ " $(ps -o args= -p $pid)" =~ $DEV_ARGS_RE ]] || continue
  key=$(proc_key $pid)
  flag=${new_flags[$key]:-${flags[$key]:--}}
  if [[ $flag != *o* ]]; then
    age="${days}d $(( hours ))h"; (( days == 0 )) && age="${hours}h"
    notify "Forgotten dev server: $(proc_desc $pid)" \
      "Running $age with no parent app · PID $pid · $(proc_cwd $pid)" $pid $key
    flag=${flag#-}o
  fi
  new_flags[$key]=$flag
done

# --- carry forward "already notified" flags for processes still alive --------
for key flag in ${(kv)flags}; do
  [[ -n ${new_flags[$key]} || $flag == - ]] && continue
  pid=${key%%:*}
  [[ $(proc_key $pid) == $key ]] && new_flags[$key]=$flag
done

: > "$STATE"
for key in ${(k)new_flags} ${(k)new_strikes}; do
  print -r -- "$key ${new_strikes[$key]:-0} ${new_flags[$key]:--}"
done | sort -u > "$STATE"

# keep the log small
[[ -f $LOG ]] && (( $(wc -l < "$LOG") > 500 )) && tail -300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
wait   # for any open alerts (they give up after 270 s)
exit 0
