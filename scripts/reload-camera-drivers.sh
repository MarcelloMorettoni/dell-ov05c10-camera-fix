#!/bin/bash
# Reload ov05c10 + IPU6 ISYS without rebooting (e.g. right after install.sh).
# Briefly stops your PipeWire session (audio drops for a few seconds).
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
U=${SUDO_USER:?run via sudo from your desktop user}
USER_ID=$(id -u "$U")
usersd() { sudo -u "$U" XDG_RUNTIME_DIR=/run/user/$USER_ID systemctl --user "$@"; }

UNITS="pipewire-pulse.socket pipewire-pulse.service pipewire.socket pipewire.service wireplumber.service"
trap 'usersd start pipewire.socket pipewire-pulse.socket pipewire wireplumber pipewire-pulse' EXIT
usersd stop $UNITS
sleep 1

if fuser /dev/media0 >/dev/null 2>&1; then
    echo "Camera still in use by:"; fuser -v /dev/media0 2>&1; exit 1
fi

modprobe -r intel_ipu6_isys || { echo "could not unload intel_ipu6_isys"; exit 1; }
modprobe -r ov05c10        || { echo "could not unload ov05c10"; modprobe intel_ipu6_isys; exit 1; }
modprobe ov05c10
sleep 1
modprobe intel_ipu6_isys
sleep 2

echo "ov05c10 loaded from: $(modinfo -n ov05c10)"
dmesg | grep -E 'ov05c10.*using shared' | tail -2
echo "PipeWire is restarted on exit. Open a camera app (e.g. GNOME Snapshot)."
