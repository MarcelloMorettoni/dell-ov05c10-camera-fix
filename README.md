# dell-ov05c10-camera-fix

A patched Linux driver that makes the built-in webcam work on the **Dell Pro 14 Plus (PB14250)**. It may also help other Intel IPU6 laptops where an **OmniVision OV05C10** RGB sensor shares its power controller with a **Himax HM1092** IR sensor.

It ships as a DKMS module, so it rebuilds itself after every kernel update and is signed for Secure Boot.

> Tested on: Dell Pro 14 Plus PB14250 (SKU 0CE8, BIOS 2.18.1), Intel Core Ultra 7 255U, Ubuntu 26.04.1, kernel 7.0.0-43-generic, GNOME Snapshot via PipeWire + libcamera.

---

## Are you affected?

You probably are if **all** of these are true:

- The laptop has an Intel IPU6 camera (`lspci` shows `Intel Corporation Meteor Lake IPU [8086:7d19]` or similar).
- The kernel finds the sensor:
  ```
  intel-ipu6 0000:00:05.0: Found supported sensor OVTI05C1:00
  ```
- Camera apps show a camera ("Internal front camera", "Built-in Front Camera"), the privacy LED may turn on, but the picture is black or the app hangs, and the kernel log shows:
  ```
  intel_ipu6_isys.isys intel_ipu6.isys.40: stream stop time out
  intel_ipu6_isys.isys intel_ipu6.isys.40: stream close time out
  ```
- This prints `INT3472:...-dvdd -> i2c-HIMX1092:00...`, i.e. the camera's power rail is assigned to the IR sensor instead of the RGB sensor:
  ```bash
  sudo grep -i int3472 /sys/kernel/debug/regulator/supply_map
  ```

Run `sudo ./scripts/diagnose.sh` to check all of this at once.

## Why this exists

Dell certifies this laptop for Ubuntu 24.04 LTS with Canonical's OEM camera stack. On newer releases (Ubuntu 26.04, kernel 7.0) the camera was detected but never delivered a single frame. I tried both camera stacks, Intel's proprietary HAL (`icamerasrc`) and libcamera, and both timed out the same way. Every driver was loaded and the sensor answered on I2C, yet nothing came out.

The sensor was simply never switched on properly. It took a day of digging through kernel debugfs and the laptop's ACPI tables to find out why. This repo packages the fix so nobody else has to repeat that.

## Root cause

The camera module contains two sensors that share **one** ACPI power device, `INT3472` / `\_SB.PC00.DSC0`:

| ACPI device | Sensor | Role |
|---|---|---|
| `OVTI05C1` (`LNK1`) | OmniVision OV05C10, 5 MP | RGB webcam |
| `HIMX1092` (`LNK0`) | Himax HM1092 | IR (face login) |

The kernel's `int3472` driver registers the shared resources, but maps them **only to the first consumer it finds**, which is `HIMX1092`:

- the **`dvdd` handshake regulator**, a GPIO on the USB-IO bridge (`INTC10B5`). It powers the sensor and signals the Intel vision chip (`INTC10E0`, "CVS") that the host wants to stream.
- the **19.2 MHz sensor master clock**, enabled through an ACPI `_DSM` method.

```
# /sys/kernel/debug/regulator/supply_map
INT3472:0c-dvdd -> i2c-HIMX1092:00.dvdd

# /sys/kernel/debug/clk/clk_summary  (no consumer at all)
INT3472:0c-clk   0  0  0  19200000 ... deviceless  no_connection_id
```

The `ov05c10` driver treats both resources as optional. When it doesn't find them it silently continues, and starts streaming a sensor that is unclocked and never got its power handshake. The sensor still answers on I2C, so nothing obviously fails. The IPU6 just never receives a frame.

## The fix

`ov05c10.c` is Intel's latest upstream driver from [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers), commit `e52f5e8` (which includes `b4622b1`, "update command to meet CVS"), plus one small change. When the driver finds **no** `dvdd` regulator or clock of its own, it borrows the ones mapped to the IR sensor:

- **`dvdd` regulator:** a regulator *supply alias* from `i2c-OVTI05C1:00` to `i2c-HIMX1092:00`.
- **Clock:** `clk_get_sys("i2c-HIMX1092:00", NULL)`.

Nothing else changes. The patch is in [`patches/`](patches/). The peer device is a module parameter:

```bash
# default
options ov05c10 power_peer=i2c-HIMX1092:00
# disable the workaround
options ov05c10 power_peer=
```

## Requirements

- Ubuntu 26.04 (or another distro with kernel ≥ 6.12, IPU6 in-tree driver, and DKMS).
- The USB-IO bridge and vision chip drivers. On Ubuntu:
  ```bash
  sudo apt install linux-modules-usbio-generic linux-modules-vision-generic
  ```
- libcamera + PipeWire camera support, the default on Ubuntu desktop:
  ```bash
  sudo apt install libcamera-tools libspa-0.2-libcamera gstreamer1.0-libcamera
  ```
- `dkms` and kernel headers. `install.sh` installs them if they're missing.

- Access to `/dev/udmabuf` for libcamera's software ISP. `install.sh` adds a udev rule giving the `video` group access, so it also works when PipeWire starts before login.

Intel's proprietary HAL (`libcamhal`, `icamerasrc`, `v4l2-relayd`) is **not** needed. Everything works through libcamera.

## Install

```bash
git clone https://github.com/MarcelloMorettoni/dell-ov05c10-camera-fix.git
cd dell-ov05c10-camera-fix
sudo ./install.sh
sudo reboot
```

Then open **Camera** (GNOME Snapshot) or any app that uses PipeWire.

To skip the reboot, `sudo ./scripts/reload-camera-drivers.sh` reloads the drivers in place. It restarts PipeWire, so audio drops for a few seconds.

### Secure Boot

DKMS signs the module with the local Machine Owner Key (`/var/lib/shim-signed/mok/MOK.der`). If you already use other DKMS drivers, that key is usually enrolled already, and `install.sh` tells you. If it isn't:

```bash
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
sudo reboot   # choose "Enroll MOK" in the blue MokManager screen
```

### Verify

```bash
modinfo -F version ov05c10          # 1.0.0-dell-ov05c10-camera-fix
journalctl -k -b | grep 'using shared'
# ov05c10 i2c-OVTI05C1:00: using shared clock from i2c-HIMX1092:00 (19200000 Hz)
# ov05c10 i2c-OVTI05C1:00: using shared dvdd regulator from i2c-HIMX1092:00
```

## Kernel updates

Nothing to do. DKMS (`AUTOINSTALL=yes`) rebuilds and signs the module for each new kernel. Check with:

```bash
dkms status dell-ov05c10-camera-fix
```

## Uninstall

```bash
sudo ./uninstall.sh
sudo reboot
```

## Browsers and apps

- **GNOME Snapshot, OBS (PipeWire source):** work through PipeWire.
- **Firefox:** uses PipeWire. If the camera is missing, set `media.webrtc.camera.allow-pipewire` to `true` in `about:config`.
- **Chrome / Chromium:** enable `chrome://flags/#enable-webrtc-pipewire-camera`.
- **Apps that open `/dev/video*` directly:** they won't see the camera, because IPU6 has no plain V4L2 webcam node. Use PipeWire, or `libcamerify <app>` from `libcamera-tools`.

## Troubleshooting

| Symptom | What to try |
|---|---|
| Worked before reboot, "camera unavailable" after; `journalctl --user -u wireplumber` shows `Could not open any dma-buf provider` / `disabling software debayering` | PipeWire started before you logged in (user lingering, `loginctl show-user $USER -p Linger`) and couldn't open `/dev/udmabuf`. `install.sh` installs `udev/72-libcamera-udmabuf.rules`, which fixes this permanently. Quick fix: `systemctl --user restart pipewire pipewire-pulse wireplumber`. |
| The first capture right after install/reload times out | Close and reopen the app. The first stream after a driver (re)load was occasionally flaky in testing; later ones worked every time. |
| `modinfo -n ov05c10` doesn't point to `updates/dkms` | Another package ships an override; check `dkms status` and `ls /lib/modules/$(uname -r)/updates/`. |
| Module fails to load (`Key was rejected by service`) | The MOK isn't enrolled; see [Secure Boot](#secure-boot). |
| No `using shared ...` lines in the log | Your laptop doesn't have `HIMX1092`, or it's at a different path; check `scripts/diagnose.sh` and set `power_peer`. |
| `GPIO type 0x02 unknown; the sensor may not work` | Harmless for the RGB camera: that pin drives the IR flood LED. |
| Image looks dim or has a colour cast | libcamera's software ISP has no tuning file for this sensor yet (`ov05c10.yaml`), so it uses an uncalibrated default. |

Please open an issue with the output of `sudo ./scripts/diagnose.sh` if it doesn't work for you, and also if it **does** work on a different model, so the list below can grow.

## Confirmed hardware

| Model | CPU | OS / kernel | Status |
|---|---|---|---|
| Dell Pro 14 Plus PB14250 (SKU 0CE8) | Core Ultra 7 255U | Ubuntu 26.04.1 / 7.0.0-43 | ✅ works |

## Upstream

This is a workaround. The proper fix belongs in the kernel's `int3472` driver, which should map shared resources to every sensor on the power device, or in Intel's `ov05c10`. It has been reported upstream to [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers/issues) (link to the issue to follow). Related: intel/ipu6-drivers#417, intel/ipu7-drivers#26, Launchpad bug [#2147409](https://bugs.launchpad.net/bugs/2147409).

## Credits and license

- `ov05c10.c` © Intel Corporation, from [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers), GPL-2.0.
- Shared power/clock workaround, packaging and scripts: GPL-2.0, see [LICENSE](LICENSE).

**Disclaimer:** this replaces a kernel driver. It's provided as is, without warranty. It changes nothing in firmware or BIOS, and `uninstall.sh` plus a reboot fully reverts it.
