#!/bin/bash
# Remove the DKMS module; the stock ov05c10 driver is used again after reboot.
set -euo pipefail
PKG=dell-ov05c10-camera-fix
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

for ver in $(dkms status "$PKG" 2>/dev/null | sed -n 's#^[^/]*/\([^,:]*\).*#\1#p' | sort -u); do
    echo "==> Removing $PKG/$ver"
    dkms remove "$PKG/$ver" --all || true
    rm -rf "/usr/src/$PKG-$ver"
done
rm -f /etc/udev/rules.d/72-libcamera-udmabuf.rules && udevadm control --reload
depmod -a
echo "==> ov05c10 that will load: $(modinfo -n ov05c10 2>/dev/null || echo none)"
echo "==> Reboot to switch back to the stock driver."
