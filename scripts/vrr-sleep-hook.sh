#!/bin/bash
# systemd-sleep hook: on resume, flip VRR to the opposite state and back
# (forces a full modeset). Workaround for GNOME/Mutter (GB#189260-class bug,
# see mutter#4111/#3419) picking the wrong backlight/display after resume.
# Installed as /lib/systemd/system-sleep/vrr-hook.sh (must be root-owned, root:root, 0755).

TARGET_USER="simone"
TARGET_UID="$(id -u "$TARGET_USER")"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus"
export XDG_RUNTIME_DIR="/run/user/${TARGET_UID}"

run_as_user() {
    sudo -u "$TARGET_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" /home/"$TARGET_USER"/bin/toggle-vrr.sh "$1"
}

case "$1/$2" in
    post/*)
        sleep 2   # give the display/compositor a moment to come back up
        run_as_user kick
        ;;
esac
