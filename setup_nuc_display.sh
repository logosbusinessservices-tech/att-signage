#!/usr/bin/env bash
# ============================================================================
# setup_nuc_display.sh — one-time setup that turns a NUC into an unattended
# welcome-screen display. Safe to run again (it skips what's already done).
#
# Run it as the normal NUC user (not with sudo), from a Terminal opened on the
# NUC's own desktop. It asks for your password when it needs admin rights.
#     ./setup_nuc_display.sh
# Then reboot.
#
# What it does:
#   1. Installs Chromium (snap), the xset screen tool and Python 3
#   2. Turns on automatic login for this user
#   3. Switches the desktop from Wayland to X11 (needed for screen control)
#   4. Sets the timezone to Asia/Kolkata and turns on automatic time sync
#   5. Stops the NUC from ever sleeping or suspending
#   6. Turns off screen blanking, the lock screen, notifications, the update
#      window and crash-report pop-ups
#   7. Starts signage_controller.sh automatically at every login
#   8. Connects the announcements board to the website (asks for the
#      website address and the NUC key; can be skipped and done later)
#   9. Removes the old cron-based signage schedule, if present
# ============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_NAME="$(id -un)"
GDM_CONF="/etc/gdm3/custom.conf"
AUTOSTART_DIR="${HOME}/.config/autostart"

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user (e.g. ./setup_nuc_display.sh), not with sudo." >&2
  exit 1
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  echo "Run this from a Terminal opened on the NUC's desktop (not over SSH):" >&2
  echo "the desktop settings can only be changed from inside the desktop session." >&2
  exit 1
fi

# The Chromium snap can only open files in non-hidden folders under $HOME.
case "$HERE" in
  "$HOME"/*) ;;
  *) echo "Move this folder somewhere inside ${HOME} first (Chromium can't read ${HERE})." >&2
     exit 1 ;;
esac
if [[ "${HERE#"$HOME"/}" == .* || "$HERE" == */.* ]]; then
  echo "This folder is inside a hidden (dot) folder, which Chromium can't read." >&2
  echo "Move it to a normal folder such as ${HOME}/att/signage." >&2
  exit 1
fi

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${VERSION_ID:-}" != "22.04" ]; then
    note "WARNING: written for Ubuntu 22.04; this is ${PRETTY_NAME:-unknown}. Continuing."
  fi
fi

echo "Setting up the welcome-screen display for user '${USER_NAME}'."
echo "Signage folder: ${HERE}"
sudo -v

# Files copied from Windows can carry CRLF line endings, which break bash.
sed -i 's/\r$//' "${HERE}"/*.sh "${HERE}"/*.conf "${HERE}"/*.py "${HERE}"/*.html 2>/dev/null || true

# ---------------------------------------------------------------------------
step "1/9 Installing Chromium, the xset screen tool and Python 3"
sudo apt-get update -y
sudo apt-get install -y x11-xserver-utils python3
if snap list chromium >/dev/null 2>&1; then
  note "Chromium already installed."
else
  sudo snap install chromium
fi
# Keep automatic Chromium updates out of working hours.
sudo snap set system refresh.timer=20:00-23:00

# ---------------------------------------------------------------------------
step "2/9 + 3/9 Automatic login for '${USER_NAME}' and X11 instead of Wayland"
if [ ! -f "$GDM_CONF" ]; then
  printf '[daemon]\n' | sudo tee "$GDM_CONF" >/dev/null
fi
if [ ! -f "${GDM_CONF}.rvnl-backup" ]; then
  sudo cp "$GDM_CONF" "${GDM_CONF}.rvnl-backup"
  note "Backed up the original to ${GDM_CONF}.rvnl-backup"
fi
sudo sed -i -E '/^[[:space:]]*#?[[:space:]]*(WaylandEnable|AutomaticLoginEnable|AutomaticLogin)[[:space:]]*=/d' "$GDM_CONF"
if grep -q '^\[daemon\]' "$GDM_CONF"; then
  sudo sed -i "/^\[daemon\]/a WaylandEnable=false\nAutomaticLoginEnable=true\nAutomaticLogin=${USER_NAME}" "$GDM_CONF"
else
  printf '\n[daemon]\nWaylandEnable=false\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$USER_NAME" \
    | sudo tee -a "$GDM_CONF" >/dev/null
fi
note "Takes effect after the reboot."

# ---------------------------------------------------------------------------
step "4/9 Timezone Asia/Kolkata and automatic time sync"
sudo timedatectl set-timezone Asia/Kolkata
sudo timedatectl set-ntp true
note "Now: $(date)"

# ---------------------------------------------------------------------------
step "5/9 Never sleep or suspend"
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null

# ---------------------------------------------------------------------------
step "6/9 No screen blanking, lock screen, notifications or pop-ups"
gset() {
  if gsettings writable "$1" "$2" >/dev/null 2>&1; then
    if gsettings set "$1" "$2" "$3"; then
      note "$1 $2 = $3"
    else
      note "WARNING: could not set $1 $2"
    fi
  else
    note "skipped $1 $2 (not available on this system)"
  fi
}
gset org.gnome.desktop.session idle-delay 0
gset org.gnome.desktop.screensaver lock-enabled false
gset org.gnome.desktop.screensaver idle-activation-enabled false
gset org.gnome.desktop.lockdown disable-lock-screen true
gset org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "'nothing'"
gset org.gnome.settings-daemon.plugins.power idle-dim false
gset org.gnome.desktop.notifications show-banners false

mkdir -p "$AUTOSTART_DIR"
# Hide the "Software Updater" window; security updates still install silently.
if [ -f /etc/xdg/autostart/update-notifier.desktop ]; then
  cp /etc/xdg/autostart/update-notifier.desktop "${AUTOSTART_DIR}/update-notifier.desktop"
  printf 'Hidden=true\n' >> "${AUTOSTART_DIR}/update-notifier.desktop"
  note "Software Updater window disabled for ${USER_NAME}."
fi
# Crash-report ("System program problem detected") pop-ups.
sudo systemctl disable --now apport.service >/dev/null 2>&1 || true
if [ -f /etc/default/apport ]; then
  sudo sed -i 's/^enabled=1/enabled=0/' /etc/default/apport
fi
note "Crash-report pop-ups disabled."

# ---------------------------------------------------------------------------
step "7/9 Start the signage controller at every login"
chmod +x "${HERE}/signage_controller.sh" "${HERE}/start_signage.sh" "${HERE}/stop_signage.sh" \
  "${HERE}/sync_messages.py"
cat > "${AUTOSTART_DIR}/rvnl-signage.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=RVNL Welcome Screen
Comment=Shows the RVNL welcome page during working hours
Exec="${HERE}/signage_controller.sh"
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
note "Installed ${AUTOSTART_DIR}/rvnl-signage.desktop"

# ---------------------------------------------------------------------------
step "8/9 Connect the announcements board to the website"
SECRETS="${HERE}/signage.secrets"
configure_secrets=yes
if [ -f "$SECRETS" ]; then
  read -r -p "    Already connected. Change the website address or key? [y/N] " answer
  [[ "$answer" =~ ^[Yy] ]] || configure_secrets=no
fi
if [ "$configure_secrets" = yes ]; then
  note "Enter the website BACKEND address (the API, not the page people log into),"
  note "e.g. https://your-backend.azurewebsites.net. Press Enter to skip for now."
  read -r -p "    Backend address: " api_url
  api_url="${api_url%/}"
  if [ -z "$api_url" ]; then
    note "Skipped: the monitor shows only the welcome slide until this is set."
  elif [[ ! "$api_url" =~ ^https?://[^[:space:]]+$ || "$api_url" == *[\"\']* ]]; then
    note "That doesn't look like an address (must start with https://). Skipped; run this again."
  else
    read -r -s -p "    NUC key (the website's EDGE_API_KEY; hidden while typing): " edge_key
    echo
    if [ -z "$edge_key" ]; then
      note "No key entered. Skipped; run this again."
    elif [[ "$edge_key" == *[\"\'[:space:]]* ]]; then
      note "The key can't contain quotes or spaces. Skipped; run this again."
    else
      ( umask 077; printf 'API_URL="%s"\nEDGE_KEY="%s"\n' "$api_url" "$edge_key" > "$SECRETS" )
      chmod 600 "$SECRETS"
      unset edge_key
      note "Saved to ${SECRETS} (readable only by ${USER_NAME})."
      # Restart the sync so it uses the new settings; the controller relaunches it.
      pkill -f -- 'sync_messages\.py' 2>/dev/null || true
      if python3 "${HERE}/sync_messages.py" --once; then
        note "Connection OK."
      else
        note "WARNING: could not fetch the announcements. Check the address and key"
        note "(run this script again to change them). The NUC keeps retrying meanwhile."
      fi
    fi
  fi
else
  note "Keeping the existing connection settings."
fi

# ---------------------------------------------------------------------------
step "9/9 Removing the old cron signage schedule (if any)"
if crontab -l 2>/dev/null | grep -q 'RVNL_SIGNAGE'; then
  { crontab -l | grep -v 'RVNL_SIGNAGE' || true; } | crontab -
  note "Old cron entries removed."
else
  note "None found."
fi

# ---------------------------------------------------------------------------
cat <<EOF

Setup complete.

Next:
  1. Reboot:              sudo reboot
  2. After it comes back, open a Terminal and check:
                          ${HERE}/signage_controller.sh --status
     "Desktop session" must say x11 and "Controller" must say running.

Schedule: ${HERE}/signage.conf     Log: ${HERE}/signage.log
Announcements sync log: ${HERE}/sync.log
EOF
