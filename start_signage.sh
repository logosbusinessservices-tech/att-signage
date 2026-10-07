#!/usr/bin/env bash
# ============================================================================
# start_signage.sh — show the RVNL welcome slide fullscreen on the NUC monitor.
#
# It wakes the monitor, stops it from sleeping, and opens signage/welcome.html
# in Chromium's "kiosk" mode (fullscreen, no tabs, no address bar).
#
# You normally don't run this yourself: signage_controller.sh calls it at the
# start of working hours and whenever the page needs reopening. Running it by
# hand (from a terminal on the NUC's desktop) is useful for testing:
#     ./start_signage.sh
# It does nothing if the welcome page is already showing.
#
# One-time NUC setup (Chromium, auto-login, X11, ...) is done by
# setup_nuc_display.sh.
# ============================================================================

set -euo pipefail

# Folder this script lives in, so it works no matter where it is called from.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLIDE_URL="file://${HERE}/welcome.html"

# The browser draws on the primary screen (:0). If your desktop session uses a
# different display, change this. Most single-user NUCs are :0.
export DISPLAY="${DISPLAY:-:0}"
# Ubuntu 22.04 installs Chromium as a snap, which lives in /snap/bin.
export PATH="${PATH}:/snap/bin"

if pgrep -f -- '--kiosk.*welcome\.html' >/dev/null 2>&1; then
  echo "Welcome page is already showing."
  exit 0
fi

# --- Wake the monitor and keep it awake. ------------------------------------
# These are best-effort; ignore errors on headless/no-X setups.
xset dpms force on 2>/dev/null || true   # wake it if it was switched off
xset s off      2>/dev/null || true   # no screensaver
xset s noblank  2>/dev/null || true   # never blank the screen
xset -dpms      2>/dev/null || true   # disable monitor power management

# --- Pick whichever Chromium binary exists on this machine. ------------------
BROWSER=""
for candidate in chromium chromium-browser google-chrome; do
  if command -v "$candidate" >/dev/null 2>&1; then
    BROWSER="$candidate"
    break
  fi
done

if [ -z "$BROWSER" ]; then
  echo "ERROR: no Chromium/Chrome found. Install it with:" >&2
  echo "  sudo snap install chromium" >&2
  exit 1
fi

echo "Launching signage with '$BROWSER' on DISPLAY=$DISPLAY"
echo "Slide: $SLIDE_URL"

# --kiosk                 : true fullscreen, no window chrome, cannot be clicked away
# --incognito             : no history/profile clutter building up over months
# --password-store=basic  : no "unlock your keyring" prompt after auto-login
# --no-first-run etc.     : no welcome / default-browser prompts
# --noerrdialogs          : never pop up "Chromium didn't shut down correctly"
# --overscroll/--pinch    : a stray touch/swipe can't navigate or zoom the page
exec "$BROWSER" \
  --kiosk \
  --incognito \
  --password-store=basic \
  --no-first-run \
  --no-default-browser-check \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=Translate \
  --overscroll-history-navigation=0 \
  --disable-pinch \
  --check-for-update-interval=31536000 \
  --start-fullscreen \
  "$SLIDE_URL"
