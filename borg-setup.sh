#!/usr/bin/env bash
# borg-setup.sh - create an encrypted Borg repository on the given device
# Usage: sudo ./borg-setup.sh <device> [repo-name] [--key <file>] [--format] [--fstab] [--mount <path>]
set -euo pipefail

usage() {
  echo "Usage: sudo $0 <device> [repo-name] [--key <file>] [--format] [--fstab] [--mount <path>]"
  echo "  device     block device or partition, e.g. sdc2 or /dev/sdc2"
  echo "  repo-name  repository directory name, default: borg-repo"
  echo "  --key      key export path, default: /root/<repo-name>-<date>.key"
  echo "  --format   format the device as ext4 (erases ALL data, asks for confirmation)"
  echo "  --fstab    add an /etc/fstab entry so the device mounts at boot (with nofail)"
  echo "  --mount    mount point, default /mnt/backup"
  exit 1
}

DEV=""; REPO_NAME=""; KEY=""; FORMAT=0; FSTAB=0; MNT=/mnt/backup
while [[ $# -gt 0 ]]; do
  case $1 in
    --format) FORMAT=1 ;;
    --fstab)  FSTAB=1 ;;
    --key)    KEY=${2:?missing key file path}; shift ;;
    --mount)  MNT=${2:?missing mount point}; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *)
      # Positional arguments: first the device, then the repository name
      if [[ -z $DEV ]]; then
        DEV=$1
      elif [[ -z $REPO_NAME ]]; then
        REPO_NAME=$1
      else
        echo "Unexpected extra argument: $1"; usage
      fi
      ;;
  esac
  shift
done

[[ -n $DEV ]] || usage
REPO_NAME=${REPO_NAME:-borg-repo}
# The name becomes a directory name, so keep it simple and safe
if [[ ! $REPO_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid repo name '$REPO_NAME'. Use letters, digits, '.', '_' or '-' (no leading symbol, no slashes)."
  exit 1
fi

[[ $DEV == /dev/* ]] || DEV=/dev/$DEV
[[ $EUID -eq 0 ]] || { echo "Please run with sudo."; exit 1; }
[[ -b $DEV ]] || { echo "Block device not found: $DEV"; exit 1; }

# Safety check: abort if the device or any of its partitions is mounted (this also protects the system disk)
if lsblk -nro MOUNTPOINTS "$DEV" | grep -q .; then
  echo "$DEV is mounted. Unmount it first."; exit 1
fi
# Whole disk that has partitions: require the user to name a partition
if [[ $(lsblk -dnro TYPE "$DEV") == disk && $(lsblk -nro NAME "$DEV" | wc -l) -gt 1 ]]; then
  echo "$DEV is a whole disk with partitions. Please specify a partition (e.g. ${DEV}1)."; exit 1
fi
mountpoint -q "$MNT" && { echo "Mount point $MNT is already in use."; exit 1; }

echo "== Target device =="
lsblk -o NAME,SIZE,MODEL,FSTYPE,LABEL,UUID "$DEV"
FSTYPE=$(blkid -o value -s TYPE "$DEV" || true)

if [[ $FORMAT -eq 1 ]]; then
  echo "WARNING: this will erase ALL data on $DEV."
  read -rp "Type the device path ($DEV) to confirm: " ans
  [[ $ans == "$DEV" ]] || { echo "Cancelled."; exit 1; }
  mkfs.ext4 -L borgbackup "$DEV"
  FSTYPE=ext4
elif [[ $FSTYPE != ext4 ]]; then
  echo "Filesystem is '${FSTYPE:-none}', not ext4. Use --format to create ext4 (erases data)."
  exit 1
fi

UUID=$(blkid -o value -s UUID "$DEV")
mkdir -p "$MNT"
mount "$DEV" "$MNT"
echo "Mounted $DEV at $MNT (UUID=$UUID)"

command -v borg >/dev/null || { apt-get update && apt-get install -y borgbackup; }

# Store the passphrase in a root-only file so unattended backups can use it
PASSFILE=/root/.config/borg/passphrase
mkdir -p "$(dirname "$PASSFILE")"
if [[ ! -s $PASSFILE ]]; then
  read -rsp "Set a Borg passphrase: " p1; echo
  read -rsp "Repeat the passphrase: " p2; echo
  [[ -n $p1 && $p1 == "$p2" ]] || { echo "Passphrase is empty or does not match."; exit 1; }
  (umask 077; printf '%s' "$p1" > "$PASSFILE")
fi
chmod 600 "$PASSFILE"
export BORG_PASSCOMMAND="cat $PASSFILE"

REPO=$MNT/$REPO_NAME
if [[ -d $REPO ]]; then
  echo "Repository already exists, skipping init: $REPO"
else
  borg init --encryption=repokey-blake2 "$REPO"
fi

# Export the key so the repository stays recoverable if the drive's copy is lost
KEY=${KEY:-/root/$REPO_NAME-$(date +%F).key}
mkdir -p "$(dirname "$KEY")"
borg key export "$REPO" "$KEY"
chmod 600 "$KEY"

if [[ $FSTAB -eq 1 ]] && ! grep -q "UUID=$UUID" /etc/fstab; then
  echo "UUID=$UUID $MNT ext4 defaults,nofail,noatime 0 2" >> /etc/fstab
  echo "Added entry to /etc/fstab"
fi

echo
echo "== Done =="
echo "Repository:      $REPO"
echo "UUID:            $UUID"
echo "Passphrase file: $PASSFILE (root only)"
echo "Key backup:      $KEY  <- copy this somewhere else"
borg info "$REPO"
