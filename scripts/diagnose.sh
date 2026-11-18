#!/bin/bash
# Read-only diagnostics for the IPU6 + OV05C10 camera. Run with sudo for the
# regulator/clock/GPIO sections (debugfs is root-only). Changes nothing.
section() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

section "System"
echo "Model : $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null) (SKU $(cat /sys/class/dmi/id/product_sku 2>/dev/null))"
echo "BIOS  : $(cat /sys/class/dmi/id/bios_version 2>/dev/null)"
echo "Kernel: $(uname -r)"
echo "OS    : $(. /etc/os-release; echo "$PRETTY_NAME")"
mokutil --sb-state 2>/dev/null

section "Camera devices in ACPI (status 15 = present)"
for d in OVTI05C1:00 HIMX1092:00 INTC10E0:00 INTC10B5:00; do
    p=/sys/bus/acpi/devices/$d
    [ -d "$p" ] && echo "$d status=$(cat $p/status 2>/dev/null || echo n/a) path=$(cat $p/path)"
done
for p in /sys/bus/acpi/devices/INT3472:*; do
    [ "$(cat $p/status 2>/dev/null)" = 15 ] && echo "$(basename $p) status=15 path=$(cat $p/path)"
done
lspci -nn | grep -iE 'IPU|Multimedia controller'

section "Driver"
echo "ov05c10 module file : $(modinfo -n ov05c10 2>/dev/null || echo 'not found')"
v=$(modinfo -F version ov05c10 2>/dev/null); echo "ov05c10 version     : ${v:-(no version tag: stock driver or a manual build)}"
echo "power_peer param    : $(cat /sys/module/ov05c10/parameters/power_peer 2>/dev/null || echo '(not the patched driver)')"
dkms status dell-ov05c10-camera-fix 2>/dev/null

section "Kernel log"
journalctl -k -b --no-pager 2>/dev/null | grep -E 'ov05c10|OVTI05C1|int3472|stream (stop|close) time out|Intel CVS' \
    | grep -v 'Modules linked' | tail -20

section "Shared power / clock (root only)"
if [ -r /sys/kernel/debug/regulator/supply_map ]; then
    grep -i int3472 /sys/kernel/debug/regulator/supply_map
    grep -i int3472 /sys/kernel/debug/regulator/regulator_summary
    grep -i int3472 /sys/kernel/debug/clk/clk_summary
    echo "(a working setup shows the clock with a consumer, not 'deviceless')"
else
    echo "run with sudo to see the regulator/clock mapping"
fi
for r in /sys/class/regulator/regulator.*; do
    grep -q 'INT3472.*dvdd' $r/name 2>/dev/null || continue
    echo "$(cat $r/name): state=$(cat $r/state) users=$(cat $r/num_users) consumers: $(ls $r | grep -iE 'ovti|himx' | tr '\n' ' ')"
done

section "libcamera software ISP buffers"
ls -l /dev/udmabuf 2>/dev/null; getfacl -p /dev/udmabuf 2>/dev/null | grep -E '^(user|group):[a-z]'
echo "user lingering: $(loginctl show-user "${SUDO_USER:-$USER}" -p Linger --value 2>/dev/null)"
if [ -n "${SUDO_USER:-}" ]; then UJ=(sudo -u "$SUDO_USER" journalctl --user); else UJ=(journalctl --user); fi
"${UJ[@]}" -b --no-pager -u wireplumber -u pipewire 2>/dev/null \
    | grep -E 'DmaBufAllocator|software ISP' | tail -3
echo "(any 'Could not open any dma-buf provider' above = camera unavailable in apps)"

section "PipeWire cameras"
wpctl status 2>/dev/null | sed -n '/^Video/,/^Settings/p' | head -15
