# XDJ-RX3 Firmware Emulation on Lenovo Duet 1

Running the Pioneer XDJ-RX3 v1.19 ARM32 firmware on a Lenovo Duet 1
(MediaTek MT8183 / `google-krane`) under postmarketOS. Autostarts as a
systemd service, renders to the built-in 1200×1920 DSI panel rotated 270°,
accepts touch input, and mounts hot-plugged USB sticks as rekordbox media.

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
```

Idempotent — re-running skips completed steps. If `recover-firmware.py`
hangs (it's interactive, sometimes the prompt is hidden behind `tee`),
Ctrl+C and run it manually from `~/Rx3-flx4/rx3-handoff`, then re-run.

---

## What works

| Feature         | Status                                                |
|-----------------|-------------------------------------------------------|
| RX3 UI on panel | ✅ rotation 270, 1200×1920 native                     |
| Touch           | ✅ taps land on on-screen buttons                     |
| USB media       | ✅ FAT32 sticks mounted via fuse-overlayfs, firmware reads SOURCE → USB1 |
| Autostart       | ✅ systemd `oneshot` with `KillMode=none`             |
| Audio           | ❌ firmware engine stalls before writing to the PCM   |

---

## Prerequisites

The installer pulls these via `apk add`. Listed here for reference.

```bash
sudo apk add \
    git bash \
    build-base gcc g++ make patch linux-headers binutils \
    gcc-armv7 binutils-armv7 musl-armv7 musl-dev-armv7 libstdc++-dev-armv7 \
    fuse-overlayfs exfatprogs alsa-utils \
    py3-pillow py3-cryptography \
    rsync 7zip \
    freetype-dev pkgconf font-dejavu libpng-dev \
    strace lsof coreutils
```

The armv7 toolchain is installed as
`armv7-alpine-linux-musleabihf-gcc` and symlinked to
`arm-linux-gnueabi-gcc` in `/usr/local/bin`, because the upstream
`build-rootfs.sh` hardcodes the Debian cross-compiler name. Kernel uapi
headers (`asm`, `asm-generic`, `linux`) are symlinked from `/usr/include`
into the armv7 sysroot.

---

## Installation (manual, step by step)

### 1. Clone and patch the repo

```bash
cd ~
git clone https://github.com/mutlisensor/Rx3-flx4.git
cd Rx3-flx4/rx3-handoff
chmod +x *.sh
```

**Patch `build-rootfs.sh`** for the Alpine sysroot path:

```bash
sed -i 's|arm-linux-gnueabi-gcc -shared -fPIC|arm-linux-gnueabi-gcc --sysroot=/usr/armv7-alpine-linux-musleabihf -shared -fPIC|' build-rootfs.sh
sed -i 's|apt install gcc-arm-linux-gnueabi|apk add gcc-armv7 musl-dev-armv7|' build-rootfs.sh
```

**Patch `patch-player.py`** to fix a NULL-pointer crash in
`getPcController`. On the Duet, the global `IUiObjManager` singleton at
`0x026867c0` is NULL when a JuceTimer fires, so the firmware dereferences
NULL at offset 0x9c:

```bash
sed -i "s|(b/'rbp-pi').write_bytes(p)|# getPcController: return NULL instead of deref'ing a NULL singleton (JuceTimer fires before init).\nwords(0x31df70,0xe3a00000)\n(b/'rbp-pi').write_bytes(p)|" patch-player.py
grep -n '31df70' patch-player.py
```

**Patch `usb-hotplug.sh`** — the upstream uses `pgrep -x rbp-pi`, which
never matches the chroot-wrapped player. `pgrep -x` compares against the
`comm` field (truncated to 15 chars, derived from the binary path).
`pgrep -f` matches the full command line:

```bash
sed -i 's|pgrep -x rbp-pi|pgrep -f rbp-pi|' usb-hotplug.sh
grep -n 'pgrep' usb-hotplug.sh
```

**Rewrite `asound.conf`** for the Duet's stereo internal card. Note `hw:0,0`
not `plughw:0,0` — dmix rejects `plughw` as a slave with
`snd_pcm_dmix_open) dmix plugin can be only connected to hw plugin`.
And the rate is 48000 because the MT8183 card reports `RATE: 48000`
(singular, not a range):

```bash
cp asound.conf asound.conf.orig
cat > asound.conf <<'EOF'
pcm.rx3mix {
 type dmix
 ipc_key 5396531
 ipc_key_add_uid true
 slave {
  pcm "hw:0,0"
  format S16_LE
  rate 48000
  channels 2
 }
 bindings { 0 0 1 1 }
}
pcm.rx3out { type plug  slave.pcm "rx3mix" }
pcm.rx3cue { type plug  slave.pcm "rx3mix" }
EOF
```

### 2. Recover the firmware

You need a legitimate copy of the XDJ-RX3 v1.19 firmware. The scripts
download it from AlphaTheta and decrypt it using the AES key from Pioneer's
GPL source distribution.

```bash
python3 recover-firmware.py
python3 extract_cramfs.py
```

Must finish with `Extraction complete.` If it doesn't, `runtime-symlinks.json`
won't exist and the next step will fail.

### 3. Build the chroot

```bash
./build-rootfs.sh 2>&1 | tee /tmp/build-rootfs.log
```

Expect `== done` and a size around 109 MB.

### 4. Set up chroot runtime files

```bash
echo "hw:0" | sudo tee ~/rx3-rootfs/etc/rx3-ctl
cp asound.conf ~/rx3-rootfs/etc/asound.conf
sudo ./mount-rx3.sh
sudo mkdir -p ~/rx3-rootfs/proc/asound
sudo mount --bind /proc/asound ~/rx3-rootfs/proc/asound
```

The `/proc/asound` bind is required: the firmware enumerates card info
through `/proc/asound/cards`, which doesn't exist inside the chroot
otherwise. `mount-rx3.sh` doesn't set it up — it only mounts `/dev` and
`/tmp`.

### 5. Compile the host helper binaries

These run natively (aarch64) on the Duet.

```bash
cd ~/Rx3-flx4/rx3-handoff

gcc -O2 -DRX3_ROOT_PATH='"/home/user/rx3-rootfs"' \
    -o ~/rx3-touch-bridge touch-bridge.c

gcc -O2 -DRX3_ROOT_PATH='"/home/user/rx3-rootfs"' \
    $(pkg-config --cflags freetype2) \
    -o ~/rx3-fb-present fb-present.c \
    $(pkg-config --libs freetype2)
```

Verify with `readelf`, NOT `file | grep aarch64` — the busybox `file`
applet's output is not reliable for this check:

```bash
for b in ~/rx3-fb-present ~/rx3-touch-bridge; do
    readelf -h "$b" | grep -E 'Class|Machine'
done
# Expect: Class: ELF64 / Machine: AArch64
```

### 6. Find the touch device

The touchscreen is `hid-over-i2c 27C6:0E30` but the kernel creates **four**
event interfaces with that base name:

```
event3   hid-over-i2c 27C6:0E30                ← bare, has ABS_MT ranges
event4   hid-over-i2c 27C6:0E30 Stylus         ← zeroed ranges
event5   hid-over-i2c 27C6:0E30 Stylus         ← no ABS_MT axes at all
event6   hid-over-i2c 27C6:0E30 UNKNOWN        ← zeroed ranges
```

The bridge needs the bare one — the only one with real
`ABS_MT_POSITION_X/Y` values. Auto-detect:

```bash
for e in /dev/input/event*; do
    n=$(basename "$e")
    name=$(cat /sys/class/input/$n/device/name 2>/dev/null)
    [ "$name" = "hid-over-i2c 27C6:0E30" ] || continue
    printf '=== %s (%s) ===\n' "$e" "$name"
    sudo timeout 2 ~/rx3-touch-bridge "$e" ~/rx3-rootfs/dev/tsc2007_2-0048 2>&1 | head -1
done
```

The correct device prints:

```
touch bridge: touchscreen, panel 1200x1920 rotate 90, canvas 1200x1920 at 0,0, touch 0..7200 x 0..11520
```

(the `rotate 90` is because `RX3_ROTATE` wasn't set; the service passes 270)

The wrong ones print `touch ranges: Invalid argument`.

**`eventN` numbers shuffle across reboots.** The udev symlink (step 10
below) fixes this permanently.

### 7. Set rotation

```bash
echo 'RX3_ROTATE=270' > ~/Rx3-flx4/rx3-handoff/rx3.conf
```

### 8. Autostart on boot (systemd)

A `oneshot` service with `KillMode=none` launches the three processes
without killing them when the script exits. See
`/usr/local/bin/rx3-service.sh` and `/etc/systemd/system/rx3.service` in
the installer.

```bash
sudo systemctl daemon-reload
sudo systemctl enable rx3.service
sudo systemctl set-default multi-user.target
```

**`systemctl set-default multi-user.target` is required.** Otherwise GDM
grabs the DRM master first and the presenter can't draw.

### 9. USB hotplug

Two udev rules forward the partition add/remove events to `usb-hotplug.sh`,
which calls `usb-attach.sh` to set up a fuse-overlayfs mount inside the
chroot:

```bash
sudo mkdir -p /etc/udev/rules.d
sudo tee /etc/udev/rules.d/99-rx3-usb.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="partition", ENV{ID_FS_TYPE}!="", RUN+="/bin/sh -c '/usr/bin/systemd-run --no-block /home/user/Rx3-flx4/rx3-handoff/usb-hotplug.sh add %E{DEVNAME}'"
ACTION=="remove", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", RUN+="/bin/sh -c '/usr/bin/systemd-run --no-block /home/user/Rx3-flx4/rx3-handoff/usb-hotplug.sh remove %E{DEVNAME}'"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=block
```

**`--action=add` is required.** Without it, `udevadm trigger` fires
**`change`** actions and the rule (`ACTION=="add"`) never matches.

Verify:

```bash
sudo journalctl -t rx3 -f    # in one terminal, then plug the stick in
```

Should show `rx3: usb1 attached /dev/sdb1`. Then on the panel: SOURCE → USB1.

### 10. Stable touch symlink

Stop `eventN` from shuffling. The rule uses `ATTRS{name}` (the kernel
device name) and matches only the bare interface:

```bash
sudo mkdir -p /etc/udev/rules.d
sudo tee /etc/udev/rules.d/99-rx3-touch.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="hid-over-i2c 27C6:0E30", SYMLINK+="input/rx3-touch"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=input
sleep 1
ls -la /dev/input/rx3-touch
```

If `/dev/input/rx3-touch → event3` appears, swap both scripts to use the
symlink. **Note the `--action=add` again** — same reason as the USB rule.

---

## Daily use

| Task                            | Command                                   |
|---------------------------------|-------------------------------------------|
| Is it running?                  | `systemctl status rx3 --no-pager`         |
| Restart                         | `sudo systemctl restart rx3`              |
| Stop and get the desktop back   | `sudo systemctl stop rx3`                 |
| Disable autostart               | `sudo systemctl disable rx3`              |
| Manual start (no systemd)       | `~/rx3-up.sh`  — **run as user, NOT sudo** |
| Player log                      | `tail -40 /tmp/player.log`                |
| Presenter log                   | `tail -40 /tmp/present.log`               |
| Touch log                       | `tail -40 /tmp/touch.log`                 |
| USB attach/detach log           | `sudo journalctl -t rx3 -f`               |

---

## Critical rules

**Never run `build-rootfs.sh` while `mount-rx3.sh` mounts are active.**
`build-rootfs.sh` uses `rsync --delete` and will fail partway through,
destroying the chroot's `/dev/fb0` and never writing `/etc/rx3-ctl`. The
installer guards against this by unmounting stale mounts before building.

**Bind mounts don't survive reboot.** `rx3-service.sh` and `rx3-up.sh`
both re-run `mount-rx3.sh` and re-bind `/proc/asound` at start.

**postmarketOS's `sudo` does not support `-E`.** It prints
`sudo: preserving the entire environment is not supported, '-E' is ignored`
but the command still runs. Use the inline form `sudo VAR=val cmd`.

**`~/rx3-up.sh` must not be run with `sudo`.** Under sudo, `~` expands to
`/root`, so all paths break. The script calls `sudo` internally where
needed. Always invoke it as your user.

**`eventN` touch numbers shuffle across reboots.** The udev symlink in
step 10 fixes this permanently.

**USB sticks must be FAT32 or exFAT.** The kernel has vfat and exfat
built in. NTFS is untested.

**`pgrep -x rbp-pi` doesn't match the chroot-wrapped player.** The process
`comm` field is truncated and derived from the binary path. `usb-hotplug.sh`
uses `pgrep -f rbp-pi` instead, which matches the full command line.

**`udevadm trigger` needs `--action=add`** to fire rules that match
`ACTION=="add"`. Without it, it fires `change` and nothing happens.

**Log files are created by root, which is why a user-run `rx3-up.sh` may
fail with `Permission denied` on `/tmp/player.log`.** The installer and
service pre-create them as `chmod 666`. If you create a custom launcher,
do the same.

---

## What we know about the audio failure

The firmware's audio engine does not write to the ALSA PCM. Everything
else — UI, touch, USB — works.

Facts established:

- The firmware binary contains the strings `cs4344audio` and
  `cs4344audiorev8`. It expects an ALSA card by that name — the Cirrus
  CS4344 codec the real RX3 uses on its I2S bus.
- `libfbshim.so` intercepts `snd_pcm_open` and redirects device names
  ending in `0`/`1` to `rx3out`/`rx3cue`. It also intercepts `snd_ctl_open`
  and forces `hw:0` (the value in `/etc/rx3-ctl`).
- Adding a `snd_ctl_card_info` override to the shim that reports the card
  name as `cs4344audiorev8` **does** start the engine — the log shows
  `DjEngineIF::audioDeviceAboutToStart() bufferSize: 64 sampleRate: 44100`.
- But the engine never writes. `strace` shows a permanent loop of
  `SNDRV_PCM_IOCTL_SYNC_PTR` with zero `WRITEI_FRAMES`. `appl_ptr` stays
  at 0 forever.
- The firmware asks for 44100 internally; the Duet card is 48000 only.
  `plug`/`rate` layers on top of dmix don't change the outcome.

The stall is internal to `rbp-pi`. Fixing it would require reverse-
engineering `playengine::UsbAudio` and its callers with Ghidra or
radare2 on ARM32 — not a configuration fix.

### DirectFB renderer race (intermittent)

Some startups crash in `DS_HW_Core_Surface_DrawImage` at
`rbp-pi + 0x19d6c4` (`systemd-coredump` shows it in thread `gui_task`).
It's intermittent — the same binary runs for hours on other boots.
`sudo systemctl restart rx3` usually clears it.

---

## Alpine-specific changes vs the original project

| Original (Pi 5)                     | Duet 1 (Alpine)                                  |
|-------------------------------------|--------------------------------------------------|
| `apt` packages                       | `apk` packages (different names)                 |
| `arm-linux-gnueabi-gcc` from Debian  | `armv7-alpine-linux-musleabihf-gcc` + symlink    |
| Cross headers in compiler sysroot    | kernel uapi headers symlinked manually           |
| `hw:2,0` (FLX4 USB audio)            | `hw:0,0` (MediaTek internal), 48 kHz stereo      |
| `RX3_ROTATE` default 90              | 270                                              |
| `systemd` unit as shipped            | needs `KillMode=none`                            |
| `--userspec` in `chroot` (GNU)       | Alpine `chroot` is BusyBox; runs as root         |
| Controller input (DDJ-FLX4 MIDI)     | none — touch only                                |
| USB power-cycle via GPIO             | N/A on MT8183, removed                           |
| `file \| grep aarch64` for verify    | `readelf -h \| grep AArch64`                     |
| Touch device named once              | four `hid-over-i2c` interfaces; pick the bare one |
| `pgrep -x rbp-pi` in hotplug         | `pgrep -f rbp-pi` (chroot-wrapped process)       |
| `udevadm trigger` without action     | needs `--action=add` to match `ACTION=="add"`    |
| No `/proc/asound` inside chroot      | bind `/proc/asound` manually                     |
| asound.conf uses `hw:2,0`            | `hw:0,0` with rate 48000; **not** `plughw` (dmix rejects it) |

---

## Known limitations

- **No audio.** The firmware's audio engine starts (with a shim that fakes
  the card name as `cs4344audiorev8`) but never writes to the PCM. This is
  internal to `rbp-pi` and requires ARM32 reverse engineering to fix.
- **Intermittent DirectFB crash** in `DS_HW_Core_Surface_DrawImage` at
  `rbp-pi+0x19d6c4`. Non-deterministic; restart usually clears it.
- **High CPU.** The player spins in `poll()` at ~20% of one core. Wrap
  with `cpulimit -l 50 -- chroot ...` if running long-term.
- **NTFS USB untested.** Use FAT32 or exFAT.
- **Touch region mapping is partial.** Only regions the bridge knows about
  (from its layout table) generate button presses. Taps outside those
  regions show `region=-1` and are ignored.

---

## Verification checklist

After install, all of these should be true:

- [ ] `/tmp/t32` prints `exit code: 42`
- [ ] `arm-linux-gnueabi-gcc --version` prints without error
- [ ] `python3 extract_cramfs.py` ends with `Extraction complete.`
- [ ] `./build-rootfs.sh` ends with `== done`
- [ ] `~/rx3-rootfs/etc/rx3-ctl` contains `hw:0`
- [ ] `readelf -h ~/rx3-fb-present | grep AArch64` prints a match
- [ ] `~/Rx3-flx4/rx3-handoff/rx3.conf` contains `RX3_ROTATE=270`
- [ ] `grep pgrep ~/Rx3-flx4/rx3-handoff/usb-hotplug.sh` shows `pgrep -f`
- [ ] `mount | grep rx3-rootfs | grep asound` shows a bind mount
- [ ] `~/rx3-up.sh` prints three non-empty PID lines and rotation 270
- [ ] RX3 UI appears on the Duet's panel
- [ ] Taps on on-screen buttons register (visible in `/tmp/touch.log` as
      `touch begin ... region=N`, and the UI responds)
- [ ] `systemctl is-enabled rx3.service` → `enabled`
- [ ] `systemctl get-default` → `multi-user.target`
- [ ] `/etc/udev/rules.d/99-rx3-usb.rules` exists
- [ ] Plug a FAT32 stick → `sudo journalctl -t rx3 -f` shows `usb1 attached`
- [ ] SOURCE → USB1 on the panel lists the stick's `PIONEER/` folder
- [ ] After reboot, `pgrep -a rbp-pi` shows a process without manual start
- [ ] `systemctl status rx3 --no-pager` shows all three processes in the cgroup

Expected to be false (documented above, not bugs to fix):

- [ ] Audio plays — the firmware engine stalls before writing, so nothing
      is heard
```

The changes from the previous version:

1. **Touch moved to ✅** in the "What works" table.
2. **Removed the entire "Touch — firmware never opens the FIFO" section** from the failure analysis. It was wrong.
3. **Renamed the failure section** to "What we know about the audio failure" — audio is the only remaining blocker.
4. **Added the touch region caveat** to Known limitations — the bridge only handles regions it knows about, others are ignored.
5. **Verification checklist** now includes a touch test as an expected-pass item.
6. **"Expected to be false"** now has only one entry: audio.

Save it as `~/README-DUET1.md`. If you want me to also update the installer to reflect any fix that came out of the touch debugging, tell me what actually changed between when touch didn't work and now — a reboot, a script run, something else — and I'll fold it in.# XDJ-RX3 Firmware Emulation on Lenovo Duet 1

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
```

Idempotent — re-running skips completed steps. If `recover-firmware.py`
hangs (it's interactive, sometimes the prompt is hidden behind `tee`),
Ctrl+C and run it manually from `~/Rx3-flx4/rx3-handoff`, then re-run.

---

## What works

| Feature         | Status                                                |
|-----------------|-------------------------------------------------------|
| RX3 UI on panel | ✅ rotation 270, 1200×1920 native                     |
| USB media       | ✅ FAT32 sticks mounted via fuse-overlayfs, firmware reads SOURCE → USB1 |
| Autostart       | ✅ systemd `oneshot` with `KillMode=none`             |
| Touch bridge    | ✅ reads taps, maps to regions, writes to FIFO        |
| Touch in UI     | ❌ firmware never opens `/dev/tsc2007_2-0048`         |
| Audio           | ❌ firmware engine stalls before writing to the PCM   |

---

## Prerequisites

The installer pulls these via `apk add`. Listed here for reference.

```bash
sudo apk add \
    git bash \
    build-base gcc g++ make patch linux-headers binutils \
    gcc-armv7 binutils-armv7 musl-armv7 musl-dev-armv7 libstdc++-dev-armv7 \
    fuse-overlayfs exfatprogs alsa-utils \
    py3-pillow py3-cryptography \
    rsync 7zip \
    freetype-dev pkgconf font-dejavu libpng-dev \
    strace lsof coreutils
```

The armv7 toolchain is installed as
`armv7-alpine-linux-musleabihf-gcc` and symlinked to
`arm-linux-gnueabi-gcc` in `/usr/local/bin`, because the upstream
`build-rootfs.sh` hardcodes the Debian cross-compiler name. Kernel uapi
headers (`asm`, `asm-generic`, `linux`) are symlinked from `/usr/include`
into the armv7 sysroot.

---

## Installation (manual, step by step)

### 1. Clone and patch the repo

```bash
cd ~
git clone https://github.com/mutlisensor/Rx3-flx4.git
cd Rx3-flx4/rx3-handoff
chmod +x *.sh
```

**Patch `build-rootfs.sh`** for the Alpine sysroot path:

```bash
sed -i 's|arm-linux-gnueabi-gcc -shared -fPIC|arm-linux-gnueabi-gcc --sysroot=/usr/armv7-alpine-linux-musleabihf -shared -fPIC|' build-rootfs.sh
sed -i 's|apt install gcc-arm-linux-gnueabi|apk add gcc-armv7 musl-dev-armv7|' build-rootfs.sh
```

**Patch `patch-player.py`** to fix a NULL-pointer crash in
`getPcController`. On the Duet, the global `IUiObjManager` singleton at
`0x026867c0` is NULL when a JuceTimer fires, so the firmware dereferences
NULL at offset 0x9c:

```bash
sed -i "s|(b/'rbp-pi').write_bytes(p)|# getPcController: return NULL instead of deref'ing a NULL singleton (JuceTimer fires before init).\nwords(0x31df70,0xe3a00000)\n(b/'rbp-pi').write_bytes(p)|" patch-player.py
grep -n '31df70' patch-player.py
```

**Patch `usb-hotplug.sh`** — the upstream uses `pgrep -x rbp-pi`, which
never matches the chroot-wrapped player. `pgrep -x` compares against the
`comm` field (truncated to 15 chars, derived from the binary path).
`pgrep -f` matches the full command line:

```bash
sed -i 's|pgrep -x rbp-pi|pgrep -f rbp-pi|' usb-hotplug.sh
grep -n 'pgrep' usb-hotplug.sh
```

**Rewrite `asound.conf`** for the Duet's stereo internal card. Note `hw:0,0`
not `plughw:0,0` — dmix rejects `plughw` as a slave with
`snd_pcm_dmix_open) dmix plugin can be only connected to hw plugin`.
And the rate is 48000 because the MT8183 card reports `RATE: 48000`
(singular, not a range):

```bash
cp asound.conf asound.conf.orig
cat > asound.conf <<'EOF'
pcm.rx3mix {
 type dmix
 ipc_key 5396531
 ipc_key_add_uid true
 slave {
  pcm "hw:0,0"
  format S16_LE
  rate 48000
  channels 2
 }
 bindings { 0 0 1 1 }
}
pcm.rx3out { type plug  slave.pcm "rx3mix" }
pcm.rx3cue { type plug  slave.pcm "rx3mix" }
EOF
```

### 2. Recover the firmware

You need a legitimate copy of the XDJ-RX3 v1.19 firmware. The scripts
download it from AlphaTheta and decrypt it using the AES key from Pioneer's
GPL source distribution.

```bash
python3 recover-firmware.py
python3 extract_cramfs.py
```

Must finish with `Extraction complete.` If it doesn't, `runtime-symlinks.json`
won't exist and the next step will fail.

### 3. Build the chroot

```bash
./build-rootfs.sh 2>&1 | tee /tmp/build-rootfs.log
```

Expect `== done` and a size around 109 MB.

### 4. Set up chroot runtime files

```bash
echo "hw:0" | sudo tee ~/rx3-rootfs/etc/rx3-ctl
cp asound.conf ~/rx3-rootfs/etc/asound.conf
sudo ./mount-rx3.sh
sudo mkdir -p ~/rx3-rootfs/proc/asound
sudo mount --bind /proc/asound ~/rx3-rootfs/proc/asound
```

The `/proc/asound` bind is required: the firmware enumerates card info
through `/proc/asound/cards`, which doesn't exist inside the chroot
otherwise. `mount-rx3.sh` doesn't set it up — it only mounts `/dev` and
`/tmp`.

### 5. Compile the host helper binaries

These run natively (aarch64) on the Duet.

```bash
cd ~/Rx3-flx4/rx3-handoff

gcc -O2 -DRX3_ROOT_PATH='"/home/user/rx3-rootfs"' \
    -o ~/rx3-touch-bridge touch-bridge.c

gcc -O2 -DRX3_ROOT_PATH='"/home/user/rx3-rootfs"' \
    $(pkg-config --cflags freetype2) \
    -o ~/rx3-fb-present fb-present.c \
    $(pkg-config --libs freetype2)
```

Verify with `readelf`, NOT `file | grep aarch64` — the busybox `file`
applet's output is not reliable for this check:

```bash
for b in ~/rx3-fb-present ~/rx3-touch-bridge; do
    readelf -h "$b" | grep -E 'Class|Machine'
done
# Expect: Class: ELF64 / Machine: AArch64
```

### 6. Find the touch device

The touchscreen is `hid-over-i2c 27C6:0E30` but the kernel creates **four**
event interfaces with that base name:

```
event3   hid-over-i2c 27C6:0E30                ← bare, has ABS_MT ranges
event4   hid-over-i2c 27C6:0E30 Stylus         ← zeroed ranges
event5   hid-over-i2c 27C6:0E30 Stylus         ← no ABS_MT axes at all
event6   hid-over-i2c 27C6:0E30 UNKNOWN        ← zeroed ranges
```

The bridge needs the bare one — the only one with real
`ABS_MT_POSITION_X/Y` values. Auto-detect:

```bash
for e in /dev/input/event*; do
    n=$(basename "$e")
    name=$(cat /sys/class/input/$n/device/name 2>/dev/null)
    [ "$name" = "hid-over-i2c 27C6:0E30" ] || continue
    printf '=== %s (%s) ===\n' "$e" "$name"
    sudo timeout 2 ~/rx3-touch-bridge "$e" ~/rx3-rootfs/dev/tsc2007_2-0048 2>&1 | head -1
done
```

The correct device prints:

```
touch bridge: touchscreen, panel 1200x1920 rotate 90, canvas 1200x1920 at 0,0, touch 0..7200 x 0..11520
```

(the `rotate 90` is because `RX3_ROTATE` wasn't set; the service passes 270)

The wrong ones print `touch ranges: Invalid argument`.

**`eventN` numbers shuffle across reboots.** The udev symlink (step 10
below) fixes this permanently.

### 7. Set rotation

```bash
echo 'RX3_ROTATE=270' > ~/Rx3-flx4/rx3-handoff/rx3.conf
```

### 8. Autostart on boot (systemd)

A `oneshot` service with `KillMode=none` launches the three processes
without killing them when the script exits. See
`/usr/local/bin/rx3-service.sh` and `/etc/systemd/system/rx3.service` in
the installer.

```bash
sudo systemctl daemon-reload
sudo systemctl enable rx3.service
sudo systemctl set-default multi-user.target
```

**`systemctl set-default multi-user.target` is required.** Otherwise GDM
grabs the DRM master first and the presenter can't draw.

### 9. USB hotplug

Two udev rules forward the partition add/remove events to `usb-hotplug.sh`,
which calls `usb-attach.sh` to set up a fuse-overlayfs mount inside the
chroot:

```bash
sudo mkdir -p /etc/udev/rules.d
sudo tee /etc/udev/rules.d/99-rx3-usb.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="partition", ENV{ID_FS_TYPE}!="", RUN+="/bin/sh -c '/usr/bin/systemd-run --no-block /home/user/Rx3-flx4/rx3-handoff/usb-hotplug.sh add %E{DEVNAME}'"
ACTION=="remove", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", RUN+="/bin/sh -c '/usr/bin/systemd-run --no-block /home/user/Rx3-flx4/rx3-handoff/usb-hotplug.sh remove %E{DEVNAME}'"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=block
```

**`--action=add` is required.** Without it, `udevadm trigger` fires
**`change`** actions and the rule (`ACTION=="add"`) never matches.

Verify:

```bash
sudo journalctl -t rx3 -f    # in one terminal, then plug the stick in
```

Should show `rx3: usb1 attached /dev/sdb1`. Then on the panel: SOURCE → USB1.

### 10. Stable touch symlink

Stop `eventN` from shuffling. The rule uses `ATTRS{name}` (the kernel
device name) and matches only the bare interface:

```bash
sudo mkdir -p /etc/udev/rules.d
sudo tee /etc/udev/rules.d/99-rx3-touch.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="hid-over-i2c 27C6:0E30", SYMLINK+="input/rx3-touch"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=input
sleep 1
ls -la /dev/input/rx3-touch
```

If `/dev/input/rx3-touch → event3` appears, swap both scripts to use the
symlink. **Note the `--action=add` again** — same reason as the USB rule.

---

## Daily use

| Task                            | Command                                   |
|---------------------------------|-------------------------------------------|
| Is it running?                  | `systemctl status rx3 --no-pager`         |
| Restart                         | `sudo systemctl restart rx3`              |
| Stop and get the desktop back   | `sudo systemctl stop rx3`                 |
| Disable autostart               | `sudo systemctl disable rx3`              |
| Manual start (no systemd)       | `~/rx3-up.sh`  — **run as user, NOT sudo** |
| Player log                      | `tail -40 /tmp/player.log`                |
| Presenter log                   | `tail -40 /tmp/present.log`               |
| Touch log                       | `tail -40 /tmp/touch.log`                 |
| USB attach/detach log           | `sudo journalctl -t rx3 -f`               |

---

## Critical rules

**Never run `build-rootfs.sh` while `mount-rx3.sh` mounts are active.**
`build-rootfs.sh` uses `rsync --delete` and will fail partway through,
destroying the chroot's `/dev/fb0` and never writing `/etc/rx3-ctl`. The
installer guards against this by unmounting stale mounts before building.

**Bind mounts don't survive reboot.** `rx3-service.sh` and `rx3-up.sh`
both re-run `mount-rx3.sh` and re-bind `/proc/asound` at start.

**postmarketOS's `sudo` does not support `-E`.** It prints
`sudo: preserving the entire environment is not supported, '-E' is ignored`
but the command still runs. Use the inline form `sudo VAR=val cmd`.

**`~/rx3-up.sh` must not be run with `sudo`.** Under sudo, `~` expands to
`/root`, so all paths break. The script calls `sudo` internally where
needed. Always invoke it as your user.

**`eventN` touch numbers shuffle across reboots.** The udev symlink in
step 10 fixes this permanently.

**USB sticks must be FAT32 or exFAT.** The kernel has vfat and exfat
built in. NTFS is untested.

**`pgrep -x rbp-pi` doesn't match the chroot-wrapped player.** The process
`comm` field is truncated and derived from the binary path. `usb-hotplug.sh`
uses `pgrep -f rbp-pi` instead, which matches the full command line.

**`udevadm trigger` needs `--action=add`** to fire rules that match
`ACTION=="add"`. Without it, it fires `change` and nothing happens.

**Log files are created by root, which is why a user-run `rx3-up.sh` may
fail with `Permission denied` on `/tmp/player.log`.** The installer and
service pre-create them as `chmod 666`. If you create a custom launcher,
do the same.

---

## What we know about the two failures

### Audio — firmware engine stalls before writing

Facts established:

- The firmware binary contains the strings `cs4344audio` and
  `cs4344audiorev8`. It expects an ALSA card by that name — the Cirrus
  CS4344 codec the real RX3 uses on its I2S bus.
- `libfbshim.so` intercepts `snd_pcm_open` and redirects device names
  ending in `0`/`1` to `rx3out`/`rx3cue`. It also intercepts `snd_ctl_open`
  and forces `hw:0` (the value in `/etc/rx3-ctl`).
- Adding a `snd_ctl_card_info` override to the shim that reports the card
  name as `cs4344audiorev8` **does** start the engine — the log shows
  `DjEngineIF::audioDeviceAboutToStart() bufferSize: 64 sampleRate: 44100`.
- But the engine never writes. `strace` shows a permanent loop of
  `SNDRV_PCM_IOCTL_SYNC_PTR` with zero `WRITEI_FRAMES`. `appl_ptr` stays
  at 0 forever.
- The firmware asks for 44100 internally; the Duet card is 48000 only.
  `plug`/`rate` layers on top of dmix don't change the outcome.

What we'd need: reverse-engineering `playengine::UsbAudio` and its callers
in `rbp-pi` to find the check that gates the write loop. Ghidra + ARM32.
Not a configuration fix.

### Touch — firmware never opens the FIFO

Facts established:

- The touch bridge opens `/dev/input/event3` successfully, reads taps, maps
  them to regions (`region=1`, `region=2`, etc.), and writes to
  `/home/user/rx3-rootfs/dev/tsc2007_2-0048` (a FIFO created by
  `mount-rx3.sh`).
- `/tmp/touch.log` shows the bridge is doing its job perfectly.
- But `lsof` on the player process shows it has **not** opened the FIFO.
  `ls -la /proc/$PID/fd/ | grep tsc` returns nothing.

The firmware never reads the touch input. Same class of problem as audio:
a firmware-internal check for a device the Duet doesn't have, which can't
be diagnosed from outside the binary.

### DirectFB renderer race

Some startups crash in `DS_HW_Core_Surface_DrawImage` at
`rbp-pi + 0x19d6c4` (`systemd-coredump` shows it in thread `gui_task`).
It's intermittent — the same binary runs for hours on other boots. It
predates all audio work (crashed at 15:05 before any shim changes). If it
happens, `sudo systemctl restart rx3` usually clears it.

---

## Alpine-specific changes vs the original project

| Original (Pi 5)                     | Duet 1 (Alpine)                                  |
|-------------------------------------|--------------------------------------------------|
| `apt` packages                       | `apk` packages (different names)                 |
| `arm-linux-gnueabi-gcc` from Debian  | `armv7-alpine-linux-musleabihf-gcc` + symlink    |
| Cross headers in compiler sysroot    | kernel uapi headers symlinked manually           |
| `hw:2,0` (FLX4 USB audio)            | `hw:0,0` (MediaTek internal), 48 kHz stereo      |
| `RX3_ROTATE` default 90              | 270                                              |
| `systemd` unit as shipped            | needs `KillMode=none`                            |
| `--userspec` in `chroot` (GNU)       | Alpine `chroot` is BusyBox; runs as root         |
| Controller input (DDJ-FLX4 MIDI)     | none — touch only                                |
| USB power-cycle via GPIO             | N/A on MT8183, removed                           |
| `file \| grep aarch64` for verify    | `readelf -h \| grep AArch64`                     |
| Touch device named once              | four `hid-over-i2c` interfaces; pick the bare one |
| `pgrep -x rbp-pi` in hotplug         | `pgrep -f rbp-pi` (chroot-wrapped process)       |
| `udevadm trigger` without action     | needs `--action=add` to match `ACTION=="add"`    |
| No `/proc/asound` inside chroot      | bind `/proc/asound` manually                     |
| asound.conf uses `hw:2,0`            | `hw:0,0` with rate 48000; **not** `plughw` (dmix rejects it) |

---

## Known limitations

- **No audio.** The firmware's audio engine starts (with a shim that fakes
  the card name as `cs4344audiorev8`) but never writes to the PCM. This is
  internal to `rbp-pi` and requires ARM32 reverse engineering to fix.
- **No touch response in the UI.** The touch bridge reads taps and writes
  to `/dev/tsc2007_2-0048`, but the firmware never opens that FIFO. Same
  class of problem as audio.
- **Intermittent DirectFB crash** in `DS_HW_Core_Surface_DrawImage` at
  `rbp-pi+0x19d6c4`. Non-deterministic; restart usually clears it.
- **High CPU.** The player spins in `poll()` at ~20% of one core. Wrap
  with `cpulimit -l 50 -- chroot ...` if running long-term.
- **NTFS USB untested.** Use FAT32 or exFAT.

---

## Verification checklist

After install, all of these should be true:

- [ ] `/tmp/t32` prints `exit code: 42`
- [ ] `arm-linux-gnueabi-gcc --version` prints without error
- [ ] `python3 extract_cramfs.py` ends with `Extraction complete.`
- [ ] `./build-rootfs.sh` ends with `== done`
- [ ] `~/rx3-rootfs/etc/rx3-ctl` contains `hw:0`
- [ ] `readelf -h ~/rx3-fb-present | grep AArch64` prints a match
- [ ] `~/Rx3-flx4/rx3-handoff/rx3.conf` contains `RX3_ROTATE=270`
- [ ] `grep pgrep ~/Rx3-flx4/rx3-handoff/usb-hotplug.sh` shows `pgrep -f`
- [ ] `mount | grep rx3-rootfs | grep asound` shows a bind mount
- [ ] `~/rx3-up.sh` prints three non-empty PID lines and rotation 270
- [ ] RX3 UI appears on the Duet's panel
- [ ] `systemctl is-enabled rx3.service` → `enabled`
- [ ] `systemctl get-default` → `multi-user.target`
- [ ] `/etc/udev/rules.d/99-rx3-usb.rules` exists
- [ ] Plug a FAT32 stick → `sudo journalctl -t rx3 -f` shows `usb1 attached`
- [ ] SOURCE → USB1 on the panel lists the stick's `PIONEER/` folder
- [ ] After reboot, `pgrep -a rbp-pi` shows a process without manual start
- [ ] `systemctl status rx3 --no-pager` shows all three processes in the cgroup

Failures expected (documented above, not bugs to fix):

- [ ] `tail /tmp/touch.log` shows `touch begin ... region=N` for taps, but
      `sudo ls -la /proc/$(pgrep -f rbp-pi | head -1)/fd/ | grep tsc`
      shows nothing — firmware doesn't read the FIFO
- [ ] `grep audioDeviceAboutToStart /tmp/player.log` may show the line, but
      `strace -p <pid> -e ioctl | grep -c WRITEI` returns 0
