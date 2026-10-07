#!/usr/bin/env bash
# ============================================================================
# stop_signage.sh — close the RVNL welcome slide and switch the monitor off.
#
# You normally don't run this yourself: signage_controller.sh calls it at the
# end of working hours. Running it by hand is useful for testing:
#     ./stop_signage.sh
# Note: during working hours the controller reopens the page within a minute.
# ============================================================================

set -uo pipefail

export DISPLAY="${DISPLAY:-:0}"

echo "Stopping signage browser..."

# Match only the welcome-page kiosk, so a browser someone opened for other
# work is left alone.
KIOSK_PATTERN='--kiosk.*welcome\.html'
pkill -f -- "$KIOSK_PATTERN" 2>/dev/null || true

# Give it a moment, then force-quit anything still hanging on.
sleep 2
pkill -9 -f -- "$KIOSK_PATTERN" 2>/dev/null || true

# Switch the monitor off (it shows a blank screen until the next start).
xset +dpms           2>/dev/null || true
xset dpms force off  2>/dev/null || true

echo "Signage stopped; monitor switched off."
