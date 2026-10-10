#!/usr/bin/env bash
# usb-backup - inspect and control the plug-in backup installed by install-auto-backup.sh
# Usage: ./usb-backup [status|progress|log|list|start|stop]
set -euo pipefail

SERVICE=borgmatic-usb
CONF=/etc/borgmatic.d/usb-backup.yaml
RULE=/etc/udev/rules.d/99-borgmatic-usb.rules
PASSFILE=/root/.config/borg/passphrase
SIZE_CACHE=/var/cache/usb-backup/source-size

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

# Total size of the source in bytes; du over 5 TB is slow, so the result is cached for a day
source_size() {
  local size
  if [[ -f $SIZE_CACHE ]] && [[ -n $(find "$SIZE_CACHE" -mmin -1440) ]] \
     && [[ $(head -n1 "$SIZE_CACHE") == "$SRC" ]]; then
    tail -n1 "$SIZE_CACHE"; return
  fi
  echo "Measuring the size of $SRC (only the first time, may take a few minutes)..." >&2
  size=$(ionice -c3 nice du -sb "$SRC" 2>/dev/null | cut -f1 || true)
  [[ -n $size ]] || return 0
  mkdir -p "$(dirname "$SIZE_CACHE")"
  printf '%s\n%s\n' "$SRC" "$size" > "$SIZE_CACHE"
  echo "$size"
}

cmd_progress() {
  local pid total elapsed read1 read2 sample=10 now avg left eta f files=()
  pid=$(borg_pid)
  [[ -n $pid ]] || { echo "No backup is running."; exit 0; }
  total=$(source_size)

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

  echo "Backup PID:    $pid (running $(duration "$elapsed"))"
  if [[ -n $total && $total -gt 0 ]]; then
    echo "Source:        $SRC ($(human "$total"))"
    echo "Read so far:   $(human "$read2") / $(human "$total") ($(awk -v r="$read2" -v t="$total" 'BEGIN {printf "%.1f%%", r*100/t}'))"
  else
    echo "Source:        $SRC (size unknown)"
    echo "Read so far:   $(human "$read2")"
  fi
  echo "Speed:         now $(human "$now")/s, average $(human "$avg")/s"
  if [[ -n $total && $avg -gt 0 ]]; then
    left=$(( total > read2 ? total - read2 : 0 ))
    eta=$(( left / avg ))
    echo "ETA:           ~$(duration "$eta") (around $(date -d "+$eta sec" '+%Y-%m-%d %H:%M'))"
  fi
  if [[ ${#files[@]} -gt 0 ]]; then
    printf 'Current file:  %s\n' "${files[@]}"
  fi
  if mountpoint -q "$MNT"; then
    df -h --output=used,avail "$MNT" | awk 'NR==2 {print "Backup drive:  used " $1 ", free " $2}'
  fi
  echo
  echo "Note: the percentage is only accurate for the first (full) backup. Later backups"
  echo "skip unchanged files, so they finish long before 'read' reaches the total."
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
