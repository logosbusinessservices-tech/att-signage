#!/usr/bin/env bash
# ============================================================================
# signage_controller.sh — keep the RVNL welcome screen on during working hours
# and the monitor off outside them.
#
# Started automatically at login (setup_nuc_display.sh installs that). Every
# minute it compares the clock with signage.conf and fixes whatever is wrong,
# so it recovers by itself from reboots, power cuts, a closed or crashed
# browser, and someone waking the monitor at night. It also keeps the
# announcements sync (sync_messages.py) running, around the clock.
#
#   ./signage_controller.sh            run the controller (normally automatic)
#   ./signage_controller.sh --status   show what it should be doing now, then exit
#
# Log of every on/off action: signage.log (this folder).
# ============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${HERE}/signage.conf"
LOG="${HERE}/signage.log"
BROWSER_LOG="${HERE}/browser.log"
CHECK_SECONDS=60
LOG_MAX_BYTES=524288
LOCK="${XDG_RUNTIME_DIR:-/tmp}/rvnl-signage-controller.lock"
KIOSK_PATTERN='--kiosk.*welcome\.html'
SYNC_SCRIPT="${HERE}/sync_messages.py"
SYNC_PATTERN='sync_messages\.py'
SECRETS="${HERE}/signage.secrets"
MESSAGES_FILE="${HERE}/messages.js"
SYNC_LOG="${HERE}/sync.log"

DEFAULT_ON_TIME="09:00"
DEFAULT_OFF_TIME="19:00"
DEFAULT_ON_DAYS="1 2 3 4 5 6"

export DISPLAY="${DISPLAY:-:0}"
# Lets --status work over SSH, where the desktop's X authority isn't set.
if [ -z "${XAUTHORITY:-}" ] && [ -f "/run/user/$(id -u)/gdm/Xauthority" ]; then
  export XAUTHORITY="/run/user/$(id -u)/gdm/Xauthority"
fi
export PATH="${PATH}:/snap/bin"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
  local size
  size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    tail -n 1000 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
  fi
}

# Read KEY="value" from signage.conf without executing the file.
conf_value() {
  local key="$1" default="$2" value
  value=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CONF" 2>/dev/null | tail -n 1)
  value="${value#*=}"
  value="${value//\"/}"
  value="${value//\'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  echo "${value:-$default}"
}

valid_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
to_minutes() { local h="${1%%:*}" m="${1##*:}"; echo $((10#$h * 60 + 10#$m)); }

CONFIG_WARNING=""
load_config() {
  ON_TIME=$(conf_value ON_TIME "$DEFAULT_ON_TIME")
  OFF_TIME=$(conf_value OFF_TIME "$DEFAULT_OFF_TIME")
  ON_DAYS=$(conf_value ON_DAYS "$DEFAULT_ON_DAYS")
  local warning=""
  if ! valid_time "$ON_TIME" || ! valid_time "$OFF_TIME" \
      || [ "$(to_minutes "$ON_TIME")" -ge "$(to_minutes "$OFF_TIME")" ]; then
    warning="invalid ON_TIME/OFF_TIME (${ON_TIME}-${OFF_TIME}); using ${DEFAULT_ON_TIME}-${DEFAULT_OFF_TIME}"
    ON_TIME="$DEFAULT_ON_TIME"
    OFF_TIME="$DEFAULT_OFF_TIME"
  fi
  if ! [[ "$ON_DAYS" =~ ^[1-7]([[:space:]]+[1-7])*$ ]]; then
    warning="${warning:+${warning}; }invalid ON_DAYS ('${ON_DAYS}'); using '${DEFAULT_ON_DAYS}'"
    ON_DAYS="$DEFAULT_ON_DAYS"
  fi
  # Log a config problem once, not every minute.
  if [ "$warning" != "$CONFIG_WARNING" ]; then
    [ -n "$warning" ] && log "WARNING signage.conf: ${warning}"
    CONFIG_WARNING="$warning"
  fi
}

should_be_on() {
  local day now
  day=$(date +%u)
  now=$(to_minutes "$(date +%H:%M)")
  [[ " ${ON_DAYS} " == *" ${day} "* ]] || return 1
  [ "$now" -ge "$(to_minutes "$ON_TIME")" ] && [ "$now" -lt "$(to_minutes "$OFF_TIME")" ]
}

browser_running() { pgrep -f -- "$KIOSK_PATTERN" >/dev/null 2>&1; }
sync_running() { pgrep -f -- "$SYNC_PATTERN" >/dev/null 2>&1; }

SYNC_NOTE=""
ensure_sync() {
  if [ ! -f "$SECRETS" ]; then
    if [ "$SYNC_NOTE" != "unconfigured" ]; then
      log "Announcements not configured (no signage.secrets): showing the welcome slide only"
      SYNC_NOTE="unconfigured"
    fi
    return
  fi
  SYNC_NOTE=""
  if ! sync_running; then
    log "Starting the announcements sync"
    python3 "$SYNC_SCRIPT" >/dev/null 2>&1 &
    disown
  fi
}

# Prints on, off, or unknown (unknown = can't reach the display).
monitor_state() {
  local q
  if ! q=$(xset q 2>/dev/null); then
    echo unknown
  elif [[ "$q" == *"Monitor is On"* || "$q" == *"DPMS is Disabled"* ]]; then
    echo on
  else
    echo off
  fi
}

reconcile() {
  load_config
  ensure_sync
  if should_be_on; then
    if ! browser_running; then
      log "Working hours: starting the welcome screen"
      "${HERE}/start_signage.sh" > "$BROWSER_LOG" 2>&1 &
      disown
    fi
    if [ "$(monitor_state)" = "off" ]; then
      xset dpms force on 2>/dev/null || true
    fi
    # Re-applied every check so nothing can blank the screen during the day.
    xset s off 2>/dev/null || true
    xset s noblank 2>/dev/null || true
    xset -dpms 2>/dev/null || true
  else
    if browser_running; then
      log "Outside working hours: closing the welcome screen and turning the monitor off"
      "${HERE}/stop_signage.sh" >> "$LOG" 2>&1
    elif [ "$(monitor_state)" = "on" ]; then
      log "Monitor was on outside working hours: turning it off"
      xset +dpms 2>/dev/null || true
      xset dpms force off 2>/dev/null || true
    fi
  fi
}

desktop_session_type() {
  local sid
  sid=$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" {print $1; exit}')
  if [ -n "$sid" ]; then
    loginctl show-session "$sid" -p Type --value 2>/dev/null || echo unknown
  else
    echo "none (nobody logged in on the monitor)"
  fi
}

if [ "${1:-}" = "--status" ]; then
  load_config
  echo "Schedule        : ${ON_TIME}-${OFF_TIME}, days ${ON_DAYS} (1=Mon ... 7=Sun)"
  echo "Now             : $(date '+%A %Y-%m-%d %H:%M %Z')"
  if should_be_on; then echo "Screen should be: ON"; else echo "Screen should be: OFF"; fi
  if browser_running; then echo "Welcome page    : running"; else echo "Welcome page    : not running"; fi
  echo "Monitor         : $(monitor_state)"
  echo "Desktop session : $(desktop_session_type)   (should be x11)"
  if ( flock -n 9 ) 9>"$LOCK" 2>/dev/null; then
    echo "Controller      : NOT running (it starts at login; reboot or log out and in)"
  else
    echo "Controller      : running"
  fi
  if [ ! -f "$SECRETS" ]; then
    echo "Announcements   : not configured (run setup_nuc_display.sh)"
  else
    if sync_running; then echo "Announcements   : sync running"; else echo "Announcements   : sync NOT running"; fi
    if [ -f "$MESSAGES_FILE" ]; then
      echo "Board file      : last changed $(date -r "$MESSAGES_FILE" '+%Y-%m-%d %H:%M')"
    else
      echo "Board file      : not downloaded yet"
    fi
    [ -f "$SYNC_LOG" ] && echo "Last sync note  : $(tail -n 1 "$SYNC_LOG")"
  fi
  [ -n "$CONFIG_WARNING" ] && echo "Config warning  : ${CONFIG_WARNING}"
  exit 0
fi

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "The signage controller is already running."
  exit 0
fi

load_config
log "Controller started (schedule ${ON_TIME}-${OFF_TIME}, days ${ON_DAYS})"
sleep 5   # let the desktop finish loading after login
while true; do
  reconcile
  sleep "$CHECK_SECONDS"
done
