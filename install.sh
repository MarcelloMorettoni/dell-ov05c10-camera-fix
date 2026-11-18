#!/bin/bash
# Install the patched ov05c10 driver as a DKMS module so it is rebuilt (and
# signed for Secure Boot) automatically for every new kernel.
#
#   sudo ./install.sh            install / upgrade
#   sudo ./install.sh --force    install even if the OV05C10 sensor is not detected
set -euo pipefail

PKG=dell-ov05c10-camera-fix
VER=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$(dirname "$0")/dkms.conf")
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
DEST=/usr/src/$PKG-$VER
KVER=$(uname -r)
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run with sudo"

# --- 1. hardware check -------------------------------------------------------
if [ "$(cat /sys/bus/acpi/devices/OVTI05C1:00/status 2>/dev/null)" != "15" ]; then
    [ $FORCE = 1 ] || die "OV05C10 sensor (ACPI OVTI05C1) not found on this machine. Use --force to install anyway."
    warn "OVTI05C1 not present, continuing because of --force"
fi
if [ "$(cat /sys/bus/acpi/devices/HIMX1092:00/status 2>/dev/null)" != "15" ]; then
    warn "HIMX1092 (IR sensor) not present: the shared power/clock workaround will be inactive;"
    warn "you only get the newer upstream ov05c10 driver."
fi

# --- 2. dependencies ---------------------------------------------------------
missing=()
command -v dkms >/dev/null || missing+=(dkms)
[ -d "/lib/modules/$KVER/build" ] || missing+=("linux-headers-$KVER")
command -v make >/dev/null && command -v gcc >/dev/null || missing+=(build-essential)
if [ ${#missing[@]} -gt 0 ]; then
    say "Installing missing packages: ${missing[*]}"
    apt-get update -qq
    apt-get install -y "${missing[@]}"
fi

for m in usbio intel_cvs; do
    modinfo "$m" >/dev/null 2>&1 && continue
    warn "kernel module '$m' not found. On Ubuntu install it with:"
    warn "  sudo apt install linux-modules-usbio-generic linux-modules-vision-generic"
done
command -v wpctl >/dev/null && ! ls /usr/lib/*/spa-0.2/libcamera >/dev/null 2>&1 && \
    warn "PipeWire libcamera plugin missing; apps won't see the camera: sudo apt install libspa-0.2-libcamera"

# --- 3. Secure Boot ----------------------------------------------------------
if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
    MOK=/var/lib/shim-signed/mok/MOK.der
    if [ -f "$MOK" ] && mokutil --test-key "$MOK" 2>&1 | grep -q 'already enrolled'; then
        say "Secure Boot: DKMS signing key is enrolled, the module will load"
    else
        warn "Secure Boot is enabled but the DKMS signing key is not enrolled yet."
        warn "After this script, run:  sudo mokutil --import $MOK"
        warn "then reboot and choose 'Enroll MOK' in the blue MokManager screen."
    fi
fi

# --- 4. remove previous versions / manual overrides --------------------------
for old in $(dkms status "$PKG" 2>/dev/null | sed -n 's#^[^/]*/\([^,:]*\).*#\1#p' | sort -u); do
    say "Removing previous $PKG/$old"
    dkms remove "$PKG/$old" --all || true
    rm -rf "/usr/src/$PKG-$old"
done
for f in /lib/modules/*/updates/ov05c10.ko /lib/modules/*/updates/ov05c10.ko.zst; do
    [ -f "$f" ] || continue
    say "Removing manually installed override $f"
    rm -f "$f"
done

# --- 5. DKMS add / build / install -------------------------------------------
say "Copying sources to $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$SRC_DIR/ov05c10.c" "$SRC_DIR/Makefile" "$SRC_DIR/dkms.conf" "$DEST/"

dkms add "$PKG/$VER"
dkms build "$PKG/$VER" -k "$KVER"
dkms install "$PKG/$VER" -k "$KVER" --force
depmod -a "$KVER"

# --- 6. udmabuf access for libcamera's software ISP --------------------------
say "Installing udev rule for /dev/udmabuf (video group access)"
install -m 644 "$SRC_DIR/udev/72-libcamera-udmabuf.rules" /etc/udev/rules.d/
udevadm control --reload
[ -e /dev/udmabuf ] && setfacl -m g:video:rw /dev/udmabuf
id -nG "${SUDO_USER:-root}" | grep -qw video || \
    warn "user ${SUDO_USER:-?} is not in the 'video' group: sudo usermod -aG video ${SUDO_USER:-<user>} (then log out/in)"

# --- 7. result ---------------------------------------------------------------
active=$(modinfo -n ov05c10 2>/dev/null || true)
echo
dkms status "$PKG"
say "ov05c10 that will load: $active"
if modinfo -F version ov05c10 2>/dev/null | grep -q "$PKG"; then
    say "Installed. Reboot (or run: sudo $SRC_DIR/scripts/reload-camera-drivers.sh) and open a camera app."
else
    warn "modinfo does not show the patched driver yet; check 'dkms status' and 'modinfo -n ov05c10'."
fi
