# XDJ-RX3 Firmware Emulation on Lenovo Duet 1

Running the Pioneer XDJ-RX3 v1.19 ARM32 firmware on a Lenovo Duet 1
(MediaTek MT8183 / `google-krane`) under postmarketOS. Autostarts as a
systemd service, renders to the built-in 1200×1920 DSI panel rotated 270°,
and mounts hot-plugged USB sticks as rekordbox media.

This is a port of the Pi 5 project at https://github.com/mutlisensor/Rx3-flx4
to Alpine/musl + MediaTek hardware. It does not use the Raspberry Pi code
paths unchanged — see "Alpine-specific changes" below.

---

## Tested on

| Component        | Value                                                |
|------------------|------------------------------------------------------|
| Device           | Lenovo Duet 1 (`google-krane`, MediaTek MT8183)      |
| OS               | postmarketOS (Alpine-based, **systemd**)             |
| Kernel           | 6.18.28-mt81 (aarch64 with CONFIG_COMPAT)            |
| Display          | 1200×1920 DSI panel, `mediatekdrmfb`, 32bpp, stride 4800 |
| Touchscreen      | `hid-over-i2c 27C6:0E30` (bare interface, no suffix) |
| USB              | xHCI via MTU3, host mode on USB-C                    |
| Audio card       | `mt8183_mt6358_ts3a227_max98357`, 48 kHz stereo only |
| User             | `user` (uid 10000), home `/home/user`                |
| Rotation         | 270° clockwise                                       |

The kernel must have `CONFIG_COMPAT` (32-bit ARM execution). The installer
tests this empirically with a freestanding armv7 binary.

---

## Quick install

```bash
chmod +x ~/rx3-duet1-install.sh
~/rx3-duet1-install.sh 2>&1 | tee ~/rx3-install.log
