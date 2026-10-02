# XDJ-RX3 Firmware on Lenovo Duet 1 (postmarketOS / Alpine Linux)

This repository contains the installation script and configuration wrapper to run the Pioneer XDJ-RX3 (`Rx3-flx4`) firmware stack natively on a **Lenovo Duet 1** (`google-krane` / MT8183) running **postmarketOS** or Alpine Linux with systemd.

---

## Features

- **Native Framebuffer Rendering:** Optimized rotation (`270°`) and scaling via custom presenter binaries (`rx3-fb-present`).
- **Touchscreen Integration:** Automatic bridging of the Duet 1's `hid-over-i2c` panel (`27C6:0E30`) into the chroot via `rx3-touch-bridge`.
- **Audio Tuning:** Configured with robust ALSA buffer sizes (`period_size 1024`, `buffer_size 16384`) to prevent cue/headphone dropouts on ARM processors.
- **Performance Optimized:** Locks the MediaTek CPU cores to the `performance` governor to ensure real-time audio and UI responsiveness.

---

## Prerequisites

1. Lenovo Duet 1 running postmarketOS / Alpine Linux with systemd.
2. Active internet connection.
3. XDJ-RX3 v1.19 update files & GPL source zips available for firmware recovery.

---

## Installation

1. Clone or copy your setup scripts to your home directory.
2. Run the automated install script as a **normal user** (do not run as root):

   ```bash
   bash ~/rx3-duet1-pmos.sh

```

The script is fully idempotent and will handle:

* System package installation (`apk`)
* 32-bit ARM cross-toolchain linking and execution tests
* Firmware extraction and crash-fix patches (`0x31df70` / `0x315f70`)
* Chroot building (`fuse-overlayfs`)
* Host helper binaries (`rx3-fb-present`, `rx3-touch-bridge`)
* Systemd service installation (`rx3.service` and `rx3-pointer.service`)

---

## Service Management

Both the main player and touch bridge run as automated systemd services.

### Start services manually:

```bash
sudo systemctl start rx3
sleep 15
sudo systemctl start rx3-pointer

```

### Check service status:

```bash
systemctl status rx3 rx3-pointer --no-pager

```

### View real-time logs:

```bash
journalctl -u rx3 -f
tail -f ~/rx3-player.log
tail -f ~/rx3-touch.log

```

---

## Configuration

* **Display/Rotation Settings:** Edit `~/Rx3-flx4/rx3-handoff/rx3.conf`
* **Audio Buffer Tuning:** Located in `~/Rx3-flx4/rx3-handoff/asound.conf` and `~/rx3-rootfs/etc/asound.conf`.
