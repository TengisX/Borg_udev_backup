#!/usr/bin/env bash
# usb-backup - inspect and control the plug-in backup installed by install-auto-backup.sh
# Usage: ./usb-backup [status|progress|log|list|start|stop]
set -euo pipefail

SERVICE=borgmatic-usb
CONF=/etc/borgmatic.d/usb-backup.yaml
RULE=/etc/udev/rules.d/99-borgmatic-usb.rules
PASSFILE=/root/.config/borg/passphrase
CACHE_DIR=/var/cache/usb-backup
FILE_LIST=$CACHE_DIR/files.list   # source files in the order borg reads them, NUL-separated
FILE_STATS=$CACHE_DIR/files.stats # source path, then "<file count> <total bytes>"

usage() {
  cat <<'EOF'
Usage: ./usb-backup [command]
  status   show whether a backup is running and how the last one went (default)
  progress show how far the running backup is, its speed and an ETA
           (keep watching with: watch -n 60 ./usb-backup progress)
  log      follow the live log (Ctrl+C stops watching, not the backup)
  list     list the archives in the repository (not while a backup is running)
  start    start a backup now (the drive must be plugged in)
  stop     stop a running backup (the drive is unmounted afterwards)
EOF
  exit 1
}

# Everything below needs root (journal, mounting, systemctl)
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
[[ -f $CONF && -f $RULE ]] || { echo "Backup is not installed. Run install-auto-backup.sh first."; exit 1; }

# Read the drive UUID and repository path from the files the installer wrote
UUID=$(grep -oP 'ID_FS_UUID\}=="\K[^"]+' "$RULE")
REPO=$(awk '/^[[:space:]]*- path:/ {gsub(/'\''/, "", $NF); print $NF; exit}' "$CONF")
MNT=$(dirname "$REPO")
DRIVE=/dev/disk/by-uuid/$UUID
# Source directory: the line after "source_directories:", written as - '<path>' with ' doubled
SRC=$(awk '/^source_directories:/ {getline; print; exit}' "$CONF")
SRC=${SRC#*- \'}; SRC=${SRC%\'}; SRC=${SRC//\'\'/\'}

show() { systemctl show "$SERVICE" -p "$1" --value; }
is_running() {
  local s
  s=$(show ActiveState)
  [[ $s == activating || $s == active ]]
}

cmd_status() {
  local state result start end
  state=$(show ActiveState); result=$(show Result)
  start=$(show ExecMainStartTimestamp); end=$(show ExecMainExitTimestamp)

  if is_running; then
    echo "State:        RUNNING (backup in progress)"
  elif [[ $state == failed || $result != success ]]; then
    echo "State:        FAILED ($result)"
  elif [[ -z $start ]]; then
    echo "State:        idle (no backup has run since boot)"
  else
    echo "State:        idle (last run succeeded)"
  fi
  [[ -z $start ]] || echo "Last started: $start"
  [[ -z $end ]]   || echo "Last ended:   $end"

  if [[ -e $DRIVE ]]; then
    if mountpoint -q "$MNT"; then
      echo "Backup drive: plugged in, mounted at $MNT (do not unplug yet)"
    else
      echo "Backup drive: plugged in, not mounted (safe to unplug)"
    fi
  else
    echo "Backup drive: not plugged in"
  fi

  echo
  echo "-- Last log lines --"
  journalctl -u "$SERVICE" -n 15 --no-pager -o cat
}

human() { numfmt --to=iec --suffix=B "$1"; }
duration() {
  local s=$1
  if (( s >= 86400 )); then printf '%dd %02d:%02d:%02d' $((s/86400)) $((s%86400/3600)) $((s%3600/60)) $((s%60))
  else printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
  fi
}

# PID of the "borg create" process started by the service, empty if there is none
borg_pid() {
  local cg procs p cmd re='borg.* create '
  cg=$(show ControlGroup)
  procs=/sys/fs/cgroup$cg/cgroup.procs
  if [[ -z $cg || ! -r $procs ]]; then
    pgrep -o -f "$re" || true; return 0
  fi
  while read -r p; do
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
    if [[ $cmd =~ $re ]]; then echo "$p"; return 0; fi
  done < "$procs"
}

# Write the source's regular files to $FILE_LIST in the order borg reads them (depth-first,
# each directory sorted by inode number like borg's scandir_inorder, skipping the
# exclude_patterns) and print "<file count> <total bytes>". Walking 5 TB is slow, so the
# result is cached for a day.
source_stats() {
  local stats
  if [[ -f $FILE_LIST && -f $FILE_STATS ]] && [[ -n $(find "$FILE_STATS" -mmin -1440) ]] \
     && [[ $(head -n1 "$FILE_STATS") == "$SRC" ]]; then
    tail -n1 "$FILE_STATS"; return
  fi
  echo "Listing the files in $SRC (once a day, may take a few minutes)..." >&2
  mkdir -p "$CACHE_DIR"
  stats=$(ionice -c3 nice python3 - "$SRC" "$CONF" "$FILE_LIST" <<'PY'
import fnmatch, os, sys

src, conf, out_path = sys.argv[1:4]

# exclude_patterns from the config: the "- '<pattern>'" lines after the key
excludes = []
with open(conf) as f:
    inside = False
    for line in f:
        if line.startswith('exclude_patterns:'):
            inside = True
            continue
        if inside:
            s = line.strip()
            if not s.startswith('- '):
                break
            p = s[2:].strip()
            if p[:1] == "'":
                p = p[1:-1].replace("''", "'")
            elif p[:1] == '"':
                p = p[1:-1]
            excludes.append(os.fsencode(p[3:] if p.startswith('fm:') else p))

count = size = 0

def walk(path, out):
    global count, size
    try:
        entries = sorted(os.scandir(path), key=lambda e: e.inode())
    except OSError:
        return
    for e in entries:
        if any(fnmatch.fnmatchcase(e.path, x) for x in excludes):
            continue
        try:
            if e.is_dir(follow_symlinks=False):
                walk(e.path, out)
            elif e.is_file(follow_symlinks=False):
                out.write(e.path + b'\0')
                count += 1
                size += e.stat(follow_symlinks=False).st_size
        except OSError:
            pass

with open(out_path + '.tmp', 'wb') as out:
    walk(os.fsencode(src), out)
os.replace(out_path + '.tmp', out_path)
print(count, size)
PY
  ) || return 0
  printf '%s\n%s\n' "$SRC" "$stats" > "$FILE_STATS"
  echo "$stats"
}

# Position (1-based) of a file in $FILE_LIST, empty if it is not in there
file_index() {
  grep -zxnF -m1 -- "$1" "$FILE_LIST" 2>/dev/null | cut -zd: -f1 | tr -d '\0' || true
}

cmd_progress() {
  local pid nfiles total elapsed read1 read2 sample=10 now avg left eta f files=() idx=""
  pid=$(borg_pid)
  [[ -n $pid ]] || { echo "No backup is running."; exit 0; }
  read -r nfiles total <<< "$(source_stats)"

  echo "Measuring speed (${sample}s)..." >&2
  read1=$(awk '/^rchar:/ {print $2}' "/proc/$pid/io")
  sleep "$sample"
  [[ -r /proc/$pid/io ]] || { echo "The backup finished while measuring."; exit 0; }
  read2=$(awk '/^rchar:/ {print $2}' "/proc/$pid/io")
  elapsed=$(ps -o etimes= -p "$pid" | tr -d ' ')
  now=$(( (read2 - read1) / sample ))
  avg=$(( read2 / (elapsed > 0 ? elapsed : 1) ))

  # Files from the source that borg has open right now
  for f in /proc/"$pid"/fd/*; do
    f=$(readlink "$f" 2>/dev/null) || continue
    if [[ $f == "$SRC"/* ]]; then files+=("$f"); fi
  done
  # Where that file sits in borg's reading order tells how many files are done
  if [[ ${#files[@]} -gt 0 && -n $nfiles ]]; then idx=$(file_index "${files[-1]}"); fi

  echo "Backup PID:    $pid (running $(duration "$elapsed"))"
  if [[ -n $nfiles ]]; then
    echo "Source:        $SRC ($nfiles files, $(human "$total"))"
  else
    echo "Source:        $SRC (file count unknown)"
  fi
  if [[ -n $idx ]]; then
    echo "Files done:    $idx / $nfiles ($(awk -v i="$idx" -v n="$nfiles" 'BEGIN {printf "%.1f%%", i*100/n}'))"
    left=$(( nfiles > idx ? nfiles - idx : 0 ))
    eta=$(( left * elapsed / idx ))
    echo "ETA:           ~$(duration "$eta") (around $(date -d "+$eta sec" '+%Y-%m-%d %H:%M'))"
  elif [[ -n $nfiles ]]; then
    echo "Files done:    unknown right now (borg is not reading a listed file, try again)"
  fi
  echo "Read so far:   $(human "$read2")"
  echo "Speed:         now $(human "$now")/s, average $(human "$avg")/s"
  if [[ ${#files[@]} -gt 0 ]]; then
    printf 'Current file:  %s\n' "${files[@]}"
  fi
  if mountpoint -q "$MNT"; then
    df -h --output=used,avail "$MNT" | awk 'NR==2 {print "Backup drive:  used " $1 ", free " $2}'
  fi
  echo
  echo "Note: the ETA assumes every file takes about as long as the ones so far, so it"
  echo "jumps around when borg reaches a run of very large or very small files."
}

cmd_log() {
  exec journalctl -u "$SERVICE" -f -n 30 -o cat
}

cmd_list() {
  if is_running; then echo "A backup is running; try again when it has finished."; exit 1; fi
  [[ -e $DRIVE ]] || { echo "Backup drive is not plugged in."; exit 1; }
  local mounted=0 rc=0
  if ! mountpoint -q "$MNT"; then
    mkdir -p "$MNT"
    mount "$DRIVE" "$MNT"
    mounted=1
  fi
  BORG_PASSCOMMAND="cat $PASSFILE" borg list "$REPO" || rc=$?
  if [[ $mounted -eq 1 ]]; then umount "$MNT" || true; fi
  exit "$rc"
}

cmd_start() {
  [[ -e $DRIVE ]] || { echo "Backup drive is not plugged in."; exit 1; }
  if is_running; then echo "A backup is already running."; exit 1; fi
  systemctl start --no-block "$SERVICE"
  echo "Backup started. Follow it with: ./usb-backup log"
}

cmd_stop() {
  if ! is_running; then echo "No backup is running."; exit 0; fi
  systemctl stop "$SERVICE"
  echo "Backup stopped."
}

case ${1:-status} in
  status) cmd_status ;;
  progress) cmd_progress ;;
  log)    cmd_log ;;
  list)   cmd_list ;;
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  *)      usage ;;
esac
