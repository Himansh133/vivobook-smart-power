#!/usr/bin/env bash
# smart-power: workload-aware power profile switcher for Linux laptops.
# Experimental. Firmware keeps full control of fans and thermal protection.

set -u

VERSION="0.1.0"
CONFIG_FILE="${SMART_POWER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/smart-power/config}"

# ---- defaults (override in the config file) ----
INTERVAL=10               # seconds between samples
CPU_BUSY_SUM=80           # sum of all cores' usage that counts as heavy load
                          # (100 = one full core, 400 = four full cores)
GPU_HIGH=40               # NVIDIA GPU % that counts as heavy load
UP_SAMPLES=3              # consecutive heavy samples before switching up
DOWN_SAMPLES=12           # consecutive light samples before switching down
MIN_HOLD=30               # minimum seconds between profile changes
AC_IDLE_PROFILE=balanced
AC_LOAD_PROFILE=performance
BATTERY_PROFILE=balanced  # set to power-saver if you want more battery life
TEMP_ZONE_TYPE=x86_pkg_temp
TEMP_LIMIT_C=85           # at or above this, drop to AC_IDLE_PROFILE
TEMP_RESUME_C=75          # must cool below this before performance is allowed again
USE_GPU=1                 # 0 disables NVIDIA sampling
DRY_RUN=0
ONCE=0

usage() {
  cat <<EOF
smart-power $VERSION
Usage: smart-power.sh [--dry-run] [--once] [--config FILE] [--help]
  --dry-run   log decisions, never change the profile
  --once      take one reading, print it with the decision, then exit (implies --dry-run)
  --config    use a specific config file
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --once) ONCE=1; DRY_RUN=1 ;;
    --config) shift; CONFIG_FILE="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# shellcheck disable=SC1090
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

log() { echo "smart-power: $*"; }

# ---- sanity checks ----
HAVE_PPD=1
if ! command -v powerprofilesctl >/dev/null 2>&1; then
  HAVE_PPD=0
  if [ "$DRY_RUN" -eq 0 ]; then
    log "powerprofilesctl not found. Install power-profiles-daemon." >&2
    exit 1
  fi
fi

HAVE_NVSMI=0
if [ "$USE_GPU" -eq 1 ] && command -v nvidia-smi >/dev/null 2>&1; then
  HAVE_NVSMI=1
fi

# ---- sensor discovery ----
TEMP_FILE=""
for z in /sys/class/thermal/thermal_zone*; do
  [ -r "$z/type" ] || continue
  if [ "$(cat "$z/type" 2>/dev/null)" = "$TEMP_ZONE_TYPE" ]; then
    TEMP_FILE="$z/temp"
    break
  fi
done
[ -z "$TEMP_FILE" ] && log "thermal zone '$TEMP_ZONE_TYPE' not found, temperature guard disabled"

GPU_PCI=""
for d in /sys/bus/pci/devices/*; do
  [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
  case "$(cat "$d/class" 2>/dev/null)" in
    0x03*) GPU_PCI="$d"; break ;;
  esac
done

# ---- readers ----
read_temp_c() {
  local raw
  [ -n "$TEMP_FILE" ] && raw=$(cat "$TEMP_FILE" 2>/dev/null) || { echo 0; return; }
  case "$raw" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo $((raw / 1000)) ;;
  esac
}

on_ac() {
  local p found=0
  for p in /sys/class/power_supply/*; do
    [ "$(cat "$p/type" 2>/dev/null)" = "Mains" ] || continue
    found=1
    [ "$(cat "$p/online" 2>/dev/null)" = "1" ] && return 0
  done
  # no mains entry at all (desktop or odd hardware): assume AC
  [ "$found" -eq 0 ] && return 0
  return 1
}

snapshot_cpu() {
  # fills SNAP_IDLE[] and SNAP_TOTAL[]; index 0 is all CPUs, 1..N are single cores
  local name user nice system idle iowait irq softirq steal rest i=0
  SNAP_IDLE=()
  SNAP_TOTAL=()
  while read -r name user nice system idle iowait irq softirq steal rest; do
    case "$name" in cpu*) ;; *) break ;; esac
    SNAP_IDLE[i]=$((idle + iowait))
    SNAP_TOTAL[i]=$((user + nice + system + idle + iowait + irq + softirq + steal))
    i=$((i + 1))
  done < /proc/stat
}

busy_percent() {
  # args: index. Uses PREV_* and SNAP_* arrays.
  local di=$((SNAP_IDLE[$1] - PREV_IDLE[$1])) dt=$((SNAP_TOTAL[$1] - PREV_TOTAL[$1]))
  [ "$dt" -le 0 ] && { echo 0; return; }
  echo $(((100 * (dt - di)) / dt))
}

gpu_percent() {
  local out
  [ "$HAVE_NVSMI" -eq 1 ] || { echo 0; return; }
  # do not wake a sleeping GPU just to read it
  if [ -n "$GPU_PCI" ] && [ "$(cat "$GPU_PCI/power/runtime_status" 2>/dev/null)" = "suspended" ]; then
    echo 0; return
  fi
  out=$(timeout 3 nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ')
  case "$out" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$out" ;;
  esac
}

current_profile() {
  [ "$HAVE_PPD" -eq 1 ] || { echo unknown; return; }
  powerprofilesctl get 2>/dev/null || echo unknown
}

apply_profile() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] would set profile: $1"
    return 0
  fi
  if powerprofilesctl set "$1" 2>/dev/null; then
    log "profile -> $1"
  else
    log "failed to set profile $1"
    return 1
  fi
}

cleanup() {
  [ "$DRY_RUN" -eq 0 ] && [ "$HAVE_PPD" -eq 1 ] && powerprofilesctl set balanced 2>/dev/null
  log "stopped"
  exit 0
}
trap cleanup INT TERM

# ---- main loop ----
mode=idle      # idle | load
hot=0
up=0
down=0
last_switch=$((SECONDS - MIN_HOLD))
[ "$ONCE" -eq 1 ] && INTERVAL=2

log "started v$VERSION (interval=${INTERVAL}s, dry-run=$DRY_RUN, config=$CONFIG_FILE)"
snapshot_cpu
PREV_IDLE=("${SNAP_IDLE[@]}")
PREV_TOTAL=("${SNAP_TOTAL[@]}")

while true; do
  # sleep in the background and wait, so a stop signal is handled right away
  sleep "$INTERVAL" &
  wait $!

  snapshot_cpu
  cpu=$(busy_percent 0)
  busy=0
  for ((i = 1; i < ${#SNAP_IDLE[@]}; i++)); do
    busy=$((busy + $(busy_percent "$i")))
  done
  PREV_IDLE=("${SNAP_IDLE[@]}")
  PREV_TOTAL=("${SNAP_TOTAL[@]}")
  gpu=$(gpu_percent)
  temp=$(read_temp_c)

  # thermal guard with hysteresis
  if [ "$temp" -ge "$TEMP_LIMIT_C" ]; then
    hot=1
  elif [ "$hot" -eq 1 ] && [ "$temp" -le "$TEMP_RESUME_C" ]; then
    hot=0
  fi

  # load state machine
  if [ "$busy" -ge "$CPU_BUSY_SUM" ] || [ "$gpu" -ge "$GPU_HIGH" ]; then
    up=$((up + 1)); down=0
  else
    down=$((down + 1)); up=0
  fi
  if [ "$mode" = idle ] && [ "$up" -ge "$UP_SAMPLES" ]; then
    mode=load
  elif [ "$mode" = load ] && [ "$down" -ge "$DOWN_SAMPLES" ]; then
    mode=idle
  fi
  if [ "$hot" -eq 1 ]; then mode=idle; up=0; fi

  # decide
  if ! on_ac; then
    source_name=battery; want=$BATTERY_PROFILE
  elif [ "$hot" -eq 1 ]; then
    source_name=ac; want=$AC_IDLE_PROFILE
  elif [ "$mode" = load ]; then
    source_name=ac; want=$AC_LOAD_PROFILE
  else
    source_name=ac; want=$AC_IDLE_PROFILE
  fi

  have=$(current_profile)
  log "src=$source_name cpu=${cpu}% busy=${busy} gpu=${gpu}% temp=${temp}C mode=$mode hot=$hot have=$have want=$want"

  if [ "$ONCE" -eq 1 ]; then
    exit 0
  fi

  if [ "$want" != "$have" ]; then
    # the thermal guard ignores the hold time
    if [ "$hot" -eq 1 ] || [ $((SECONDS - last_switch)) -ge "$MIN_HOLD" ]; then
      apply_profile "$want" && last_switch=$SECONDS
    fi
  fi
done
