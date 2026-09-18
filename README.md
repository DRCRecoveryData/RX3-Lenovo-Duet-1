Here's a complete README for reinstallation. Save it somewhere safe.

```markdown
# XDJ-RX3 Firmware Emulation on Lenovo Duet 1

Running the Pioneer XDJ-RX3 v1.19 ARM32 firmware on a Lenovo Duet 1
(MediaTek MT8183 / `google-krane`) under postmarketOS. Autostarts as a
systemd service, renders to the built-in 1200×1920 DSI panel rotated 270°,
and accepts touch input.

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
| Touchscreen      | `hid-over-i2c 27C6:0E30` → `/dev/input/event5`       |
| User             | `user` (uid 10000), home `/home/user`                |
| Rotation         | 270° clockwise                                       |

The kernel must have `CONFIG_COMPAT` (32-bit ARM execution). Test with a
freestanding armv7 binary before starting; if it fails with "Exec format
error" the port is impossible without a kernel rebuild.

---

## Prerequisites

Install the Alpine packages. The names differ from the Debian list in the
original project's `install.sh deps`.

```bash
sudo apk add \
    git bash \
    build-base gcc g++ make patch linux-headers \
    gcc-armv7 binutils-armv7 musl-armv7 musl-dev-armv7 libstdc++-dev-armv7 \
    fuse-overlayfs exfatprogs alsa-utils \
    py3-pillow py3-cryptography \
    rsync 7zip \
    freetype-dev pkgconf font-dejavu libpng-dev \
    strace lsof coreutils
```

Verify the armv7 toolchain is available as `arm-linux-gnueabi-gcc`:

```bash
sudo mkdir -p /usr/local/bin
sudo ln -sf /usr/bin/armv7-alpine-linux-musleabihf-gcc       /usr/local/bin/arm-linux-gnueabi-gcc
sudo ln -sf /usr/bin/armv7-alpine-linux-musleabihf-nm        /usr/local/bin/arm-linux-gnueabi-nm
sudo ln -sf /usr/bin/armv7-alpine-linux-musleabihf-objdump   /usr/local/bin/arm-linux-gnueabi-objdump
arm-linux-gnueabi-gcc --version
```

Symlink the kernel uapi headers into the armv7 sysroot so `asm/ioctl.h`
and `linux/fb.h` resolve when cross-compiling:

```bash
sudo ln -sf /usr/include/asm          /usr/armv7-alpine-linux-musleabihf/include/asm
sudo ln -sf /usr/include/asm-generic  /usr/armv7-alpine-linux-musleabihf/include/asm-generic
sudo ln -sf /usr/include/linux        /usr/armv7-alpine-linux-musleabihf/include/linux
```

Test that the kernel can run 32-bit ARM:

```bash
cat > /tmp/t32.c <<'EOF'
void _start(void) {
    __asm__ volatile ("mov r7, #1\nmov r0, #42\nsvc #0\n");
    for(;;);
}
EOF
armv7-alpine-linux-musleabihf-gcc -nostdlib -static -o /tmp/t32 /tmp/t32.c
/tmp/t32; echo "exit code: $?"
```

Should print `exit code: 42`.

---

## Installation

### 1. Clone and patch the repo

```bash
cd ~
git clone https://github.com/mutlisensor/Rx3-flx4.git
cd Rx3-flx4/rx3-handoff
```

**Patch `build-rootfs.sh`** for the Alpine sysroot path (the original uses
the Debian cross-compiler's built-in headers):

```bash
sed -i 's|arm-linux-gnueabi-gcc -shared -fPIC|arm-linux-gnueabi-gcc --sysroot=/usr/armv7-alpine-linux-musleabihf -shared -fPIC|' build-rootfs.sh
sed -i 's|apt install gcc-arm-linux-gnueabi|apk add gcc-armv7 musl-dev-armv7|' build-rootfs.sh
```

**Patch `patch-player.py`** to fix a NULL-pointer crash in `getPcController`.
On a Duet the global `IUiObjManager` singleton at `0x026867c0` is NULL when
a JuceTimer fires, so the firmware dereferences NULL at offset 0x9c. Change
the load to a "return 0":

```bash
sed -i "s|(b/'rbp-pi').write_bytes(p)|# getPcController: return NULL instead of deref'ing a NULL singleton (JuceTimer fires before init).\nwords(0x31df70,0xe3a00000)\n(b/'rbp-pi').write_bytes(p)|" patch-player.py
grep -n '31df70\|write_bytes' patch-player.py
```

**Rewrite `asound.conf`** for the Duet's stereo internal card
(`mt8183_mt6358_ts3a227_max98357`). The original targets the DDJ-FLX4's
4-channel USB interface on card 2:

```bash
cp asound.conf asound.conf.orig
cat > asound.conf <<'EOF'
# Duet 1: internal MediaTek card is 2-channel only.
pcm.rx3mix {
 type dmix
 ipc_key 5396531
 ipc_key_add_uid true
 slave {
  pcm "hw:0,0"
  format S16_LE
  rate 44100
  channels 2
  period_size 128
  buffer_size 512
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

`extract_cramfs.py` must finish with `Extraction complete.` If it doesn't,
`runtime-symlinks.json` won't exist and the next step will fail.

### 3. Build the chroot

```bash
./build-rootfs.sh 2>&1 | tee /tmp/build-rootfs.log
```

Expect `== done` and a size around 108 MB. This produces `~/rx3-rootfs`
with the ARM32 glibc chroot, the patched player, and the cross-compiled
`lib/fbshim.so`.

### 4. Set up chroot runtime files

```bash
echo "hw:0" | sudo tee ~/rx3-rootfs/etc/rx3-ctl
cp asound.conf ~/rx3-rootfs/etc/asound.conf
sudo ./mount-rx3.sh
```

`mount-rx3.sh` bind-mounts the real `/dev/snd`, `/dev/shm`, `/dev/null`
etc. into the chroot and creates a tmpfs at `/tmp`. **These mounts do not
survive a reboot.**

### 5. Compile the host helper binaries

These run natively (aarch64) on the Duet and bridge between the chroot and
the real display / input. They need to be built on the device, not
cross-compiled.

```bash
cd ~/Rx3-flx4/rx3-handoff

# touch bridge (no external deps)
gcc -O2 -DRX3_ROOT_PATH='"/home/user/rx3-rootfs"' \
    -o ~/rx3-touch-bridge touch-bridge.c

# framebuffer presenter (needs FreeType)
gcc -O2 -DRX3_ROOT_PATH='"/home/user/rx3-rootfs"' \
    $(pkg-config --cflags freetype2) \
    -o ~/rx3-fb-present fb-present.c \
    $(pkg-config --libs freetype2)

file ~/rx3-fb-present ~/rx3-touch-bridge
# both should be: ELF 64-bit LSB pie executable, ARM aarch64
```

### 6. Set rotation

```bash
echo 'RX3_ROTATE=270' > ~/Rx3-flx4/rx3-handoff/rx3.conf
```

The presenter's default for a portrait panel is 90; the Duet's DSI panel
needs 270. If the picture is wrong, try 0, 90, 180, 270 until it reads
correctly — one of them will.

### 7. Restart script

Create `~/rx3-up.sh` for manual launches. It sources `rx3-env.sh` (which
reads `rx3.conf`) and passes `RX3_ROTATE` through `sudo -E`:

```bash
cat > ~/rx3-up.sh << 'ENDOFSCRIPT'
#!/bin/bash
set -u
cd ~/Rx3-flx4/rx3-handoff
. ./rx3-env.sh

sudo pkill -f rbp-pi 2>/dev/null
sudo pkill -f rx3-fb-present 2>/dev/null
sudo pkill -f rx3-touch-bridge 2>/dev/null
sleep 1

for m in $(mount | awk '/rx3-rootfs/ {print $3}'); do
    sudo umount "$m" 2>/dev/null
done

if [ ! -f ~/rx3-rootfs/etc/rx3-ctl ]; then
    echo "rebuilding chroot..."
    ./build-rootfs.sh >/dev/null
    echo "hw:0" | sudo tee ~/rx3-rootfs/etc/rx3-ctl >/dev/null
    cp asound.conf ~/rx3-rootfs/etc/asound.conf
fi

sudo ./mount-rx3.sh >/dev/null
sudo systemctl stop gdm 2>/dev/null
sleep 1

sudo chroot ~/rx3-rootfs /bin/busybox sh -c \
    'cd /root/pdj && exec env LD_PRELOAD=/lib/fbshim.so /root/pdj/rbp-pi -a' \
    > /tmp/player.log 2>&1 &
sleep 5

sudo -E RX3_FB=/dev/fb0 RX3_ROTATE="$RX3_ROTATE" RX3_FONT=/usr/share/fonts/dejavu/DejaVuSans.ttf \
    ~/rx3-fb-present ~/rx3-rootfs/dev/fb0 > /tmp/present.log 2>&1 &

sudo -E RX3_ROTATE="$RX3_ROTATE" \
    ~/rx3-touch-bridge /dev/input/event5 ~/rx3-rootfs/dev/tsc2007_2-0048 \
    > /tmp/touch.log 2>&1 &

sleep 2
echo "rotation:  $RX3_ROTATE"
echo "player:    $(pgrep -f rbp-pi | tr '\n' ' ')"
echo "presenter: $(pgrep -f rx3-fb-present | tr '\n' ' ')"
echo "touch:     $(pgrep -f rx3-touch-bridge | tr '\n' ' ')"
ENDOFSCRIPT
chmod +x ~/rx3-up.sh
```

Run it and confirm three PIDs print and the RX3 UI appears on screen.

---

## Autostart on boot (systemd)

The Duet runs systemd, not OpenRC. A `oneshot` service with `KillMode=none`
launches the three processes without killing them when the script exits.

### Service script

```bash
sudo tee /usr/local/bin/rx3-service.sh > /dev/null << 'EOF'
#!/bin/bash
set -u
U=/home/user
H=$U/Rx3-flx4/rx3-handoff
R=$U/rx3-rootfs

case "${1:-start}" in
  start)
    systemctl stop gdm 2>/dev/null
    sleep 1
    cd "$H"
    ./mount-rx3.sh >/dev/null
    [ -f "$R/etc/rx3-ctl" ] || echo "hw:0" > "$R/etc/rx3-ctl"
    ROT=270
    [ -f "$H/rx3.conf" ] && . "$H/rx3.conf"

    chroot "$R" /bin/busybox sh -c \
      'cd /root/pdj && exec env LD_PRELOAD=/lib/fbshim.so /root/pdj/rbp-pi -a' \
      > /tmp/player.log 2>&1 &
    sleep 5

    RX3_FB=/dev/fb0 RX3_ROTATE="$ROT" RX3_FONT=/usr/share/fonts/dejavu/DejaVuSans.ttf \
      "$U/rx3-fb-present" "$R/dev/fb0" > /tmp/present.log 2>&1 &

    RX3_ROTATE="$ROT" \
      "$U/rx3-touch-bridge" /dev/input/event5 "$R/dev/tsc2007_2-0048" \
      > /tmp/touch.log 2>&1 &
    ;;
  stop)
    pkill -f rbp-pi 2>/dev/null
    pkill -f rx3-fb-present 2>/dev/null
    pkill -f rx3-touch-bridge 2>/dev/null
    systemctl start gdm 2>/dev/null
    ;;
esac
exit 0
EOF
sudo chmod +x /usr/local/bin/rx3-service.sh
```

### Unit file

```bash
sudo tee /etc/systemd/system/rx3.service > /dev/null << 'EOF'
[Unit]
Description=XDJ-RX3 firmware emulation (Lenovo Duet 1)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
KillMode=none
ExecStart=/usr/local/bin/rx3-service.sh start
ExecStop=/usr/local/bin/rx3-service.sh stop
TimeoutStartSec=180
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable rx3.service
```

### Boot to console, not GNOME

```bash
sudo systemctl set-default multi-user.target
```

Otherwise GDM grabs the DRM master first and the presenter can't draw.

Reboot. Log in if prompted. After ~15 s the RX3 UI should be on screen.

---

## Daily use

| Task                            | Command                                   |
|---------------------------------|-------------------------------------------|
| Is it running?                  | `systemctl status rx3 --no-pager`         |
| Restart                         | `sudo systemctl restart rx3`              |
| Stop and get the desktop back   | `sudo systemctl stop rx3`                 |
| Disable autostart               | `sudo systemctl disable rx3`              |
| Manual start (no systemd)       | `~/rx3-up.sh`                             |
| Player log                      | `tail -40 /tmp/player.log`                |
| Presenter log                   | `tail -40 /tmp/present.log`               |
| Touch log                       | `tail -40 /tmp/touch.log`                 |

---

## Critical rules

**Never run `build-rootfs.sh` while `mount-rx3.sh` mounts are active.**
`build-rootfs.sh` uses `rsync --delete` and will fail partway through,
destroying the chroot's `/dev/fb0` and never writing `/etc/rx3-ctl`. The
recovery is: reboot (which clears mounts), then `build-rootfs.sh`, then
recreate `rx3-ctl` and `asound.conf`, then `mount-rx3.sh`.

**Bind mounts don't survive reboot.** `rx3-service.sh` and `rx3-up.sh`
both re-run `mount-rx3.sh` at start.

**`sudo` strips environment variables.** `rx3-fb-present` and
`rx3-touch-bridge` don't read `rx3.conf` themselves — they need
`RX3_ROTATE` in their environment. Always pass it via `sudo -E
RX3_ROTATE=...` or set it as a direct argument.

---

## Alpine-specific changes vs the original project

The Pi 5 project assumes Raspbian (Debian) with glibc and systemd. On
Alpine/musl/systemd the following differ:

| Original (Pi 5)                     | Duet 1 (Alpine)                                  |
|-------------------------------------|--------------------------------------------------|
| `apt` packages                       | `apk` packages (different names)                 |
| `arm-linux-gnueabi-gcc` from Debian  | `armv7-alpine-linux-musleabihf-gcc` + symlink    |
| Cross headers in compiler sysroot    | kernel uapi headers symlinked manually           |
| `hw:2,0` (FLX4 USB audio)            | `hw:0,0` (MediaTek internal), 2 channels         |
| `RX3_ROTATE` default 90              | 270                                              |
| `systemd` unit as shipped            | needs `KillMode=none`                            |
| `--userspec` in `chroot` (GNU)       | Alpine `chroot` is BusyBox; `rx3-service.sh` runs as root, no userspec |
| Controller input (DDJ-FLX4 MIDI)     | none — touch only                                |
| USB power-cycle via GPIO             | N/A on MT8183, removed                           |

---

## Known limitations

- **No audio.** The ALSA dmix slave rejects `hw:0,0` with the firmware's
  requested config (`Invalid value for card`). The player boots silently
  and the UI works; only sound is missing. To investigate:
  `plughw:0,0` in `asound.conf`, drop the fixed rate/period, or route
  through `snd-aloop` if the kernel has it.
- **High CPU.** The player spins in `poll()` at ~20% of one core. Wrap
  with `cpulimit -l 50 -- chroot ...` if running long-term.
- **USB media untested.** Plugging in a rekordbox stick and tapping
  SOURCE → USB1 may work or may need Alpine-specific patches to
  `usb-hotplug.sh` / `rx3-mtab.sh` / `rx3-priv.sh`.
- **Touch region mapping** covers the on-screen buttons the bridge knows
  about (region=2 etc.). Taps outside mapped regions show `region=-1` and
  are ignored.

---

## Verification checklist

After install, all of these should be true:

- [ ] `/tmp/t32` prints `exit code: 42` (kernel runs 32-bit ARM)
- [ ] `arm-linux-gnueabi-gcc --version` prints without error
- [ ] `python3 extract_cramfs.py` ends with `Extraction complete.`
- [ ] `./build-rootfs.sh` ends with `== done`
- [ ] `~/rx3-rootfs/etc/rx3-ctl` contains `hw:0`
- [ ] `file ~/rx3-fb-present` says `ELF 64-bit ... ARM aarch64`
- [ ] `~/Rx3-flx4/rx3-handoff/rx3.conf` contains `RX3_ROTATE=270`
- [ ] `~/rx3-up.sh` prints three PIDs and rotation 270
- [ ] RX3 UI appears on the Duet's panel
- [ ] Taps land on on-screen buttons
- [ ] After reboot, `pgrep -a rbp-pi` shows a process without manual start
```

A few notes on it:

- **The two hard-won fixes** are called out explicitly: the `getPcController` NULL patch and the `KillMode=none` requirement. If you forget either, nothing works and the symptom is misleading.
- **The `hw:0,0` / 2-channel change** is documented in full because the original `asound.conf` silently fails on the Duet's card.
- **The "Critical rules" section** exists because you lost the chroot three times to the same mount-order mistake — worth writing down.
- **The Alpine-vs-Debian table** at the end summarises every deviation from the upstream project, which is what a future reader (or you in six months) will want.

Save it to `~/Rx3-flx4/README-DUET1.md` or fork the repo with it added. If you want a shorter "quick reference" version for the systemd service directory, say the word.
