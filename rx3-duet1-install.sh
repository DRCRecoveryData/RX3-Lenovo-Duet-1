#!/bin/bash
# rx3-duet1-install.sh
# All-in-one installer for XDJ-RX3 firmware emulation on Lenovo Duet 1
# (MediaTek MT8183 / google-krane) under postmarketOS / Alpine + systemd.
#
# Run as your normal user (NOT root). The script will sudo where needed.
#
# Usage:  bash rx3-duet1-install.sh 2>&1 | tee ~/rx3-install.log

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/mutlisensor/Rx3-flx4.git"
WORKDIR="$HOME/Rx3-flx4"
HANDOFF="$WORKDIR/rx3-handoff"
ROOTFS="$HOME/rx3-rootfs"
ROTATION=270
TOUCH_NAME="hid-over-i2c 27C6:0E30"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 0 — sanity
# ---------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "Do not run as root. Run as your normal user; the script will sudo when needed."
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "\$HOME not set or missing."
command -v apk >/dev/null || die "apk not found. This installer targets Alpine/postmarketOS."
command -v systemctl >/dev/null || die "systemd not found. This installer assumes systemd."

say "Installing on host: $(uname -a)"
say "User: $(id -un) (uid $(id -u)), HOME=$HOME"

# ---------------------------------------------------------------------------
# Step 1 — APK packages
# ---------------------------------------------------------------------------
say "Installing Alpine packages"
sudo apk add --no-cache \
    git bash \
    build-base gcc g++ make patch linux-headers binutils \
    gcc-armv7 binutils-armv7 musl-armv7 musl-dev-armv7 libstdc++-dev-armv7 \
    fuse-overlayfs exfatprogs alsa-utils \
    py3-pillow py3-cryptography \
    rsync 7zip \
    freetype-dev pkgconf font-dejavu libpng-dev \
    strace lsof coreutils

# ---------------------------------------------------------------------------
# Step 2 — armv7 toolchain symlinks
# ---------------------------------------------------------------------------
say "Setting up armv7 cross-toolchain symlinks"
sudo mkdir -p /usr/local/bin
for tool in gcc nm objdump; do
    src="/usr/bin/armv7-alpine-linux-musleabihf-${tool}"
    dst="/usr/local/bin/arm-linux-gnueabi-${tool}"
    [ -x "$src" ] || die "Missing $src — is gcc-armv7 installed?"
    sudo ln -sf "$src" "$dst"
done
arm-linux-gnueabi-gcc --version | head -1

# ---------------------------------------------------------------------------
# Step 3 — uapi headers into armv7 sysroot
# ---------------------------------------------------------------------------
say "Symlinking kernel uapi headers into armv7 sysroot"
SYSROOT=/usr/armv7-alpine-linux-musleabihf/include
[ -d "$SYSROOT" ] || die "armv7 sysroot not found at $SYSROOT"
for h in asm asm-generic linux; do
    sudo ln -sf "/usr/include/$h" "$SYSROOT/$h"
done

# ---------------------------------------------------------------------------
# Step 4 — empirical 32-bit ARM test
# ---------------------------------------------------------------------------
say "Testing 32-bit ARM execution"
cat > /tmp/t32.c <<'EOF'
void _start(void) {
    __asm__ volatile ("mov r7, #1\nmov r0, #42\nsvc #0\n");
    for(;;);
}
EOF
armv7-alpine-linux-musleabihf-gcc -nostdlib -static -o /tmp/t32 /tmp/t32.c
set +e
/tmp/t32; rc=$?
set -e
[ "$rc" = "42" ] || die "Kernel cannot run 32-bit ARM (exit=$rc). CONFIG_COMPAT is required — rebuild the kernel."
echo "    32-bit ARM OK (exit code 42)"

# ---------------------------------------------------------------------------
# Step 5 — clone & patch repo
# ---------------------------------------------------------------------------
if [ -d "$WORKDIR/.git" ]; then
    say "Repo already present at $WORKDIR — pulling"
    git -C "$WORKDIR" pull --ff-only || warn "git pull failed; continuing with local copy"
else
    say "Cloning $REPO_URL"
    git clone "$REPO_URL" "$WORKDIR"
fi
cd "$HANDOFF" || die "No rx3-handoff dir in $WORKDIR"

say "Making handoff scripts executable"
chmod +x "$HANDOFF"/*.sh

say "Patching build-rootfs.sh for Alpine sysroot"
sed -i 's|arm-linux-gnueabi-gcc -shared -fPIC|arm-linux-gnueabi-gcc --sysroot=/usr/armv7-alpine-linux-musleabihf -shared -fPIC|' build-rootfs.sh
sed -i 's|apt install gcc-arm-linux-gnueabi|apk add gcc-armv7 musl-dev-armv7|' build-rootfs.sh

say "Patching patch-player.py (getPcController NULL fix)"
if ! grep -q "31df70" patch-player.py; then
    sed -i "s|(b/'rbp-pi').write_bytes(p)|# getPcController: return NULL instead of deref'ing a NULL singleton (JuceTimer fires before init).\nwords(0x31df70,0xe3a00000)\n(b/'rbp-pi').write_bytes(p)|" patch-player.py
fi
grep -q '31df70' patch-player.py || die "patch-player.py patch failed"

say "Patching usb-hotplug.sh (pgrep -x → -f: pgrep -x never matches the chroot-wrapped player)"
if grep -q 'pgrep -x rbp-pi' usb-hotplug.sh; then
    sed -i 's|pgrep -x rbp-pi|pgrep -f rbp-pi|' usb-hotplug.sh
    echo "    patched"
else
    echo "    already patched (or pattern not found)"
fi

say "Rewriting asound.conf for Duet's internal 2-channel MediaTek card"
[ -f asound.conf.orig ] || cp asound.conf asound.conf.orig
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

# ---------------------------------------------------------------------------
# Step 6 — recover & extract firmware
# ---------------------------------------------------------------------------
if [ -f "$HANDOFF/runtime-symlinks.json" ]; then
    say "Firmware already extracted (runtime-symlinks.json present) — skipping"
else
    say "Recovering firmware (downloads from AlphaTheta and decrypts)"
    python3 recover-firmware.py || die "recover-firmware.py failed"
    python3 extract_cramfs.py 2>&1 | tee /tmp/extract.log
    grep -q "Extraction complete." /tmp/extract.log || die "extract_cramfs.py did not finish"
    [ -f "$HANDOFF/runtime-symlinks.json" ] || die "runtime-symlinks.json missing — extraction incomplete"
fi

# ---------------------------------------------------------------------------
# Step 7 — build chroot
# ---------------------------------------------------------------------------
if [ -f "$ROOTFS/etc/rx3-ctl" ] && [ -d "$ROOTFS/root/pdj" ]; then
    say "Chroot already built ($(du -sh "$ROOTFS" 2>/dev/null | cut -f1)) — skipping build"
else
    say "Building the chroot (this takes a few minutes)"
    if mount | grep -q "$ROOTFS"; then
        warn "Stale mounts on $ROOTFS detected — unmounting first"
        mapfile -t MOUNTS < <(mount | awk -v r="$ROOTFS" 'index($3, r) == 1 {print $3}' | sort -r)
        for m in "${MOUNTS[@]}"; do
            sudo umount -l -- "$m" 2>/dev/null || sudo umount -f -- "$m" 2>/dev/null || true
        done
    fi
    ./build-rootfs.sh 2>&1 | tee /tmp/build-rootfs.log
    grep -q '^== done' /tmp/build-rootfs.log || die "build-rootfs.sh did not finish — check /tmp/build-rootfs.log"
fi
say "Chroot size: $(du -sh "$ROOTFS" 2>/dev/null | cut -f1)"

# ---------------------------------------------------------------------------
# Step 8 — runtime files & mounts
# ---------------------------------------------------------------------------
say "Writing chroot runtime files"
echo "hw:0" | sudo tee "$ROOTFS/etc/rx3-ctl" >/dev/null
sudo cp "$HANDOFF/asound.conf" "$ROOTFS/etc/asound.conf"

say "Mounting chroot bind mounts"
sudo "$HANDOFF/mount-rx3.sh"

# ---------------------------------------------------------------------------
# Step 9 — host helper binaries (native aarch64)
# ---------------------------------------------------------------------------
say "Compiling touch bridge"
gcc -O2 -DRX3_ROOT_PATH="\"$ROOTFS\"" \
    -o "$HOME/rx3-touch-bridge" "$HANDOFF/touch-bridge.c"

say "Compiling framebuffer presenter"
gcc -O2 -DRX3_ROOT_PATH="\"$ROOTFS\"" \
    $(pkg-config --cflags freetype2) \
    -o "$HOME/rx3-fb-present" "$HANDOFF/fb-present.c" \
    $(pkg-config --libs freetype2)

say "Verifying host binaries are aarch64"
for bin in "$HOME/rx3-fb-present" "$HOME/rx3-touch-bridge"; do
    [ -x "$bin" ] || die "$bin missing or not executable"
    if ! readelf -h "$bin" 2>/dev/null | grep -q 'AArch64'; then
        readelf -h "$bin" | sed 's/^/      /' >&2
        die "$bin is not aarch64 — gcc built for the wrong target"
    fi
done
file "$HOME/rx3-fb-present" "$HOME/rx3-touch-bridge" || true

# ---------------------------------------------------------------------------
# Step 10 — auto-detect touch device
# ---------------------------------------------------------------------------
say "Auto-detecting touch device (name: $TOUCH_NAME)"
TOUCH_DEV=""
for e in /dev/input/event*; do
    n=$(basename "$e")
    name=$(cat "/sys/class/input/$n/device/name" 2>/dev/null || true)
    [ "$name" = "$TOUCH_NAME" ] || continue
    out=$(sudo timeout 2 "$HOME/rx3-touch-bridge" "$e" "$ROOTFS/dev/tsc2007_2-0048" 2>&1 | head -1 || true)
    if printf '%s' "$out" | grep -q '^touch bridge: touchscreen'; then
        TOUCH_DEV="$e"
        echo "    selected $e  →  $out"
        break
    fi
done
[ -n "$TOUCH_DEV" ] || die "Could not find a usable touch device named '$TOUCH_NAME'."
say "Touch device locked in as: $TOUCH_DEV"

# ---------------------------------------------------------------------------
# Step 11 — rotation config
# ---------------------------------------------------------------------------
say "Writing rotation config ($ROTATION)"
echo "RX3_ROTATE=$ROTATION" > "$HANDOFF/rx3.conf"

# ---------------------------------------------------------------------------
# Step 12 — manual launcher ~/rx3-up.sh
# ---------------------------------------------------------------------------
say "Creating ~/rx3-up.sh (touch device: $TOUCH_DEV)"
cat > "$HOME/rx3-up.sh" <<ENDOFSCRIPT
#!/bin/bash
set -u
cd ~/Rx3-flx4/rx3-handoff
. ./rx3-env.sh

sudo pkill -f rbp-pi 2>/dev/null
sudo pkill -f rx3-fb-present 2>/dev/null
sudo pkill -f rx3-touch-bridge 2>/dev/null
sleep 1

for m in \$(mount | awk '/rx3-rootfs/ {print \$3}'); do
    sudo umount "\$m" 2>/dev/null
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

sudo chroot ~/rx3-rootfs /bin/busybox sh -c \\
    'cd /root/pdj && exec env LD_PRELOAD=/lib/fbshim.so /root/pdj/rbp-pi -a' \\
    > /tmp/player.log 2>&1 &
sleep 5

sudo RX3_FB=/dev/fb0 RX3_ROTATE="\$RX3_ROTATE" RX3_FONT=/usr/share/fonts/dejavu/DejaVuSans.ttf \\
    ~/rx3-fb-present ~/rx3-rootfs/dev/fb0 > /tmp/present.log 2>&1 &

sudo RX3_ROTATE="\$RX3_ROTATE" \\
    ~/rx3-touch-bridge $TOUCH_DEV ~/rx3-rootfs/dev/tsc2007_2-0048 \\
    > /tmp/touch.log 2>&1 &

sleep 2
echo "rotation:  \$RX3_ROTATE"
echo "player:    \$(pgrep -f rbp-pi | tr '\n' ' ')"
echo "presenter: \$(pgrep -f rx3-fb-present | tr '\n' ' ')"
echo "touch:     \$(pgrep -f rx3-touch-bridge | tr '\n' ' ')"
ENDOFSCRIPT
chmod +x "$HOME/rx3-up.sh"

# ---------------------------------------------------------------------------
# Step 13 — systemd service script
# ---------------------------------------------------------------------------
say "Installing /usr/local/bin/rx3-service.sh"
sudo tee /usr/local/bin/rx3-service.sh >/dev/null <<ENDOFSVC
#!/bin/bash
set -u
U=/home/user
H=\$U/Rx3-flx4/rx3-handoff
R=\$U/rx3-rootfs

case "\${1:-start}" in
  start)
    systemctl stop gdm 2>/dev/null
    sleep 1
    cd "\$H"
    ./mount-rx3.sh >/dev/null
    [ -f "\$R/etc/rx3-ctl" ] || echo "hw:0" > "\$R/etc/rx3-ctl"
    ROT=270
    [ -f "\$H/rx3.conf" ] && . "\$H/rx3.conf"

    chroot "\$R" /bin/busybox sh -c \\
      'cd /root/pdj && exec env LD_PRELOAD=/lib/fbshim.so /root/pdj/rbp-pi -a' \\
      > /tmp/player.log 2>&1 &
    sleep 5

    RX3_FB=/dev/fb0 RX3_ROTATE="\$ROT" RX3_FONT=/usr/share/fonts/dejavu/DejaVuSans.ttf \\
      "\$U/rx3-fb-present" "\$R/dev/fb0" > /tmp/present.log 2>&1 &

    RX3_ROTATE="\$ROT" \\
      "\$U/rx3-touch-bridge" $TOUCH_DEV "\$R/dev/tsc2007_2-0048" \\
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
ENDOFSVC
sudo chmod +x /usr/local/bin/rx3-service.sh

# ---------------------------------------------------------------------------
# Step 14 — systemd unit
# ---------------------------------------------------------------------------
say "Installing /etc/systemd/system/rx3.service"
sudo tee /etc/systemd/system/rx3.service >/dev/null <<'EOF'
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

# ---------------------------------------------------------------------------
# Step 15 — USB hotplug udev rule
# ---------------------------------------------------------------------------
say "Installing /etc/udev/rules.d/99-rx3-usb.rules"
sudo mkdir -p /etc/udev/rules.d
sudo tee /etc/udev/rules.d/99-rx3-usb.rules >/dev/null <<EOF
# Hot-plugged USB storage partitions are presented to the RX3 player as USB1/USB2.
# Runs usb-hotplug.sh via systemd-run so udev doesn't block on the mount.
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="partition", ENV{ID_FS_TYPE}!="", RUN+="/bin/sh -c '/usr/bin/systemd-run --no-block $HANDOFF/usb-hotplug.sh add %E{DEVNAME}'"
ACTION=="remove", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", RUN+="/bin/sh -c '/usr/bin/systemd-run --no-block $HANDOFF/usb-hotplug.sh remove %E{DEVNAME}'"
EOF
sudo udevadm control --reload-rules 2>/dev/null || true
# --action=add is required; without it, udevadm trigger fires "change" and the
# rule (ACTION=="add") never matches.
sudo udevadm trigger --action=add --subsystem-match=block 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 16 — console boot by default (GDM must not grab DRM master)
# ---------------------------------------------------------------------------
say "Setting default target to multi-user (console, no GDM)"
sudo systemctl set-default multi-user.target

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<EOF

============================================================
  INSTALL COMPLETE
============================================================

Repo:        $WORKDIR
Chroot:      $ROOTFS  ($(du -sh "$ROOTFS" 2>/dev/null | cut -f1))
Rotation:    $ROTATION
Touch dev:   $TOUCH_DEV
Service:     rx3.service (enabled)
Default:     multi-user.target (console)
USB hotplug: /etc/udev/rules.d/99-rx3-usb.rules

Next steps
----------
1. Manual launch (recommended first time):
       ~/rx3-up.sh

2. Or reboot. After ~15 s the RX3 UI should appear on the panel.

3. Service control:
       systemctl status rx3 --no-pager
       sudo systemctl restart rx3
       sudo systemctl stop rx3        # returns you to a normal console

4. Logs:
       tail -40 /tmp/player.log
       tail -40 /tmp/present.log
       tail -40 /tmp/touch.log

5. USB:
       Plug a FAT32 stick in. Watch:
         sudo journalctl -t rx3 -f
       Then tap SOURCE → USB1 on the panel.

Notes
-----
- No audio (known limitation — the ALSA dmix slave rejects hw:0,0 with
  the firmware's requested config).
- Bind mounts do not survive reboot; the service re-runs mount-rx3.sh.
- Never run build-rootfs.sh while mount-rx3.sh mounts are active.
- The touch device eventN may shuffle across reboots. The installer
  auto-detects on each run.

Full log of this install: $HOME/rx3-install.log
EOF#!/bin/bash
# rx3-duet1-install.sh
# All-in-one installer for XDJ-RX3 firmware emulation on Lenovo Duet 1
# (MediaTek MT8183 / google-krane) under postmarketOS / Alpine + systemd.
#
# Run as your normal user (NOT root). The script will sudo where needed.
#
# Usage:  bash rx3-duet1-install.sh 2>&1 | tee ~/rx3-install.log

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/mutlisensor/Rx3-flx4.git"
WORKDIR="$HOME/Rx3-flx4"
HANDOFF="$WORKDIR/rx3-handoff"
ROOTFS="$HOME/rx3-rootfs"
ROTATION=270
TOUCH_NAME="hid-over-i2c 27C6:0E30"    # bare interface; suffixes are stylus/unknown

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 0 — sanity
# ---------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "Do not run as root. Run as your normal user; the script will sudo when needed."
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "\$HOME not set or missing."
command -v apk >/dev/null || die "apk not found. This installer targets Alpine/postmarketOS."
command -v systemctl >/dev/null || die "systemd not found. This installer assumes systemd."

say "Installing on host: $(uname -a)"
say "User: $(id -un) (uid $(id -u)), HOME=$HOME"

# ---------------------------------------------------------------------------
# Step 1 — APK packages
# ---------------------------------------------------------------------------
say "Installing Alpine packages"
sudo apk add --no-cache \
    git bash \
    build-base gcc g++ make patch linux-headers binutils \
    gcc-armv7 binutils-armv7 musl-armv7 musl-dev-armv7 libstdc++-dev-armv7 \
    fuse-overlayfs exfatprogs alsa-utils \
    py3-pillow py3-cryptography \
    rsync 7zip \
    freetype-dev pkgconf font-dejavu libpng-dev \
    strace lsof coreutils

# ---------------------------------------------------------------------------
# Step 2 — armv7 toolchain symlinks
# ---------------------------------------------------------------------------
say "Setting up armv7 cross-toolchain symlinks"
sudo mkdir -p /usr/local/bin
for tool in gcc nm objdump; do
    src="/usr/bin/armv7-alpine-linux-musleabihf-${tool}"
    dst="/usr/local/bin/arm-linux-gnueabi-${tool}"
    [ -x "$src" ] || die "Missing $src — is gcc-armv7 installed?"
    sudo ln -sf "$src" "$dst"
done
arm-linux-gnueabi-gcc --version | head -1

# ---------------------------------------------------------------------------
# Step 3 — uapi headers into armv7 sysroot
# ---------------------------------------------------------------------------
say "Symlinking kernel uapi headers into armv7 sysroot"
SYSROOT=/usr/armv7-alpine-linux-musleabihf/include
[ -d "$SYSROOT" ] || die "armv7 sysroot not found at $SYSROOT"
for h in asm asm-generic linux; do
    sudo ln -sf "/usr/include/$h" "$SYSROOT/$h"
done

# ---------------------------------------------------------------------------
# Step 4 — empirical 32-bit ARM test
# ---------------------------------------------------------------------------
say "Testing 32-bit ARM execution"
cat > /tmp/t32.c <<'EOF'
void _start(void) {
    __asm__ volatile ("mov r7, #1\nmov r0, #42\nsvc #0\n");
    for(;;);
}
EOF
armv7-alpine-linux-musleabihf-gcc -nostdlib -static -o /tmp/t32 /tmp/t32.c
set +e
/tmp/t32; rc=$?
set -e
[ "$rc" = "42" ] || die "Kernel cannot run 32-bit ARM (exit=$rc). CONFIG_COMPAT is required — rebuild the kernel."
echo "    32-bit ARM OK (exit code 42)"

# ---------------------------------------------------------------------------
# Step 5 — clone & patch repo
# ---------------------------------------------------------------------------
if [ -d "$WORKDIR/.git" ]; then
    say "Repo already present at $WORKDIR — pulling"
    git -C "$WORKDIR" pull --ff-only || warn "git pull failed; continuing with local copy"
else
    say "Cloning $REPO_URL"
    git clone "$REPO_URL" "$WORKDIR"
fi
cd "$HANDOFF" || die "No rx3-handoff dir in $WORKDIR"

say "Patching build-rootfs.sh for Alpine sysroot"
sed -i 's|arm-linux-gnueabi-gcc -shared -fPIC|arm-linux-gnueabi-gcc --sysroot=/usr/armv7-alpine-linux-musleabihf -shared -fPIC|' build-rootfs.sh
sed -i 's|apt install gcc-arm-linux-gnueabi|apk add gcc-armv7 musl-dev-armv7|' build-rootfs.sh

say "Patching patch-player.py (getPcController NULL fix)"
if ! grep -q "31df70" patch-player.py; then
    sed -i "s|(b/'rbp-pi').write_bytes(p)|# getPcController: return NULL instead of deref'ing a NULL singleton (JuceTimer fires before init).\nwords(0x31df70,0xe3a00000)\n(b/'rbp-pi').write_bytes(p)|" patch-player.py
fi
grep -q '31df70' patch-player.py || die "patch-player.py patch failed"

say "Rewriting asound.conf for Duet's internal 2-channel MediaTek card"
[ -f asound.conf.orig ] || cp asound.conf asound.conf.orig
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

# ---------------------------------------------------------------------------
# Step 6 — recover & extract firmware
# ---------------------------------------------------------------------------
if [ -f "$HANDOFF/runtime-symlinks.json" ]; then
    say "Firmware already extracted (runtime-symlinks.json present) — skipping"
else
    say "Recovering firmware (downloads from AlphaTheta and decrypts)"
    python3 recover-firmware.py || die "recover-firmware.py failed"
    python3 extract_cramfs.py 2>&1 | tee /tmp/extract.log
    grep -q "Extraction complete." /tmp/extract.log || die "extract_cramfs.py did not finish"
    [ -f "$HANDOFF/runtime-symlinks.json" ] || die "runtime-symlinks.json missing — extraction incomplete"
fi

# ---------------------------------------------------------------------------
# Step 7 — build chroot
# ---------------------------------------------------------------------------
if [ -f "$ROOTFS/etc/rx3-ctl" ] && [ -d "$ROOTFS/root/pdj" ]; then
    say "Chroot already built ($(du -sh "$ROOTFS" 2>/dev/null | cut -f1)) — skipping build"
else
    say "Building the chroot (this takes a few minutes)"
    # Guard: unmount stale bind mounts
    if mount | grep -q "$ROOTFS"; then
        warn "Stale mounts on $ROOTFS detected — unmounting first"
        mapfile -t MOUNTS < <(mount | awk -v r="$ROOTFS" 'index($3, r) == 1 {print $3}' | sort -r)
        for m in "${MOUNTS[@]}"; do
            sudo umount -l -- "$m" 2>/dev/null || sudo umount -f -- "$m" 2>/dev/null || true
        done
    fi
    ./build-rootfs.sh 2>&1 | tee /tmp/build-rootfs.log
    grep -q '^== done' /tmp/build-rootfs.log || die "build-rootfs.sh did not finish — check /tmp/build-rootfs.log"
fi
say "Chroot size: $(du -sh "$ROOTFS" 2>/dev/null | cut -f1)"

# ---------------------------------------------------------------------------
# Step 8 — runtime files & mounts
# ---------------------------------------------------------------------------
say "Writing chroot runtime files"
echo "hw:0" | sudo tee "$ROOTFS/etc/rx3-ctl" >/dev/null
sudo cp "$HANDOFF/asound.conf" "$ROOTFS/etc/asound.conf"

say "Mounting chroot bind mounts"
sudo "$HANDOFF/mount-rx3.sh"

# ---------------------------------------------------------------------------
# Step 9 — host helper binaries (native aarch64)
# ---------------------------------------------------------------------------
say "Compiling touch bridge"
gcc -O2 -DRX3_ROOT_PATH="\"$ROOTFS\"" \
    -o "$HOME/rx3-touch-bridge" "$HANDOFF/touch-bridge.c"

say "Compiling framebuffer presenter"
gcc -O2 -DRX3_ROOT_PATH="\"$ROOTFS\"" \
    $(pkg-config --cflags freetype2) \
    -o "$HOME/rx3-fb-present" "$HANDOFF/fb-present.c" \
    $(pkg-config --libs freetype2)

say "Verifying host binaries are aarch64"
for bin in "$HOME/rx3-fb-present" "$HOME/rx3-touch-bridge"; do
    [ -x "$bin" ] || die "$bin missing or not executable"
    if ! readelf -h "$bin" 2>/dev/null | grep -q 'AArch64'; then
        readelf -h "$bin" | sed 's/^/      /' >&2
        die "$bin is not aarch64 — gcc built for the wrong target"
    fi
done
file "$HOME/rx3-fb-present" "$HOME/rx3-touch-bridge" || true

# ---------------------------------------------------------------------------
# Step 10 — auto-detect touch device
# ---------------------------------------------------------------------------
say "Auto-detecting touch device (name: $TOUCH_NAME)"

TOUCH_DEV=""
for e in /dev/input/event*; do
    n=$(basename "$e")
    name=$(cat "/sys/class/input/$n/device/name" 2>/dev/null || true)
    [ "$name" = "$TOUCH_NAME" ] || continue
    # Test with the bridge — this is the authoritative check
    out=$(sudo timeout 2 "$HOME/rx3-touch-bridge" "$e" "$ROOTFS/dev/tsc2007_2-0048" 2>&1 | head -1 || true)
    if printf '%s' "$out" | grep -q '^touch bridge: touchscreen'; then
        TOUCH_DEV="$e"
        echo "    selected $e  →  $out"
        break
    fi
done

[ -n "$TOUCH_DEV" ] || die "Could not find a usable touch device with name '$TOUCH_NAME'. Check that the touchscreen driver is loaded."
say "Touch device locked in as: $TOUCH_DEV"

# ---------------------------------------------------------------------------
# Step 11 — rotation config
# ---------------------------------------------------------------------------
say "Writing rotation config ($ROTATION)"
echo "RX3_ROTATE=$ROTATION" > "$HANDOFF/rx3.conf"

# ---------------------------------------------------------------------------
# Step 12 — manual launcher ~/rx3-up.sh
# ---------------------------------------------------------------------------
say "Creating ~/rx3-up.sh (touch device: $TOUCH_DEV)"
cat > "$HOME/rx3-up.sh" <<ENDOFSCRIPT
#!/bin/bash
set -u
cd ~/Rx3-flx4/rx3-handoff
. ./rx3-env.sh

sudo pkill -f rbp-pi 2>/dev/null
sudo pkill -f rx3-fb-present 2>/dev/null
sudo pkill -f rx3-touch-bridge 2>/dev/null
sleep 1

for m in \$(mount | awk '/rx3-rootfs/ {print \$3}'); do
    sudo umount "\$m" 2>/dev/null
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

sudo chroot ~/rx3-rootfs /bin/busybox sh -c \\
    'cd /root/pdj && exec env LD_PRELOAD=/lib/fbshim.so /root/pdj/rbp-pi -a' \\
    > /tmp/player.log 2>&1 &
sleep 5

sudo RX3_FB=/dev/fb0 RX3_ROTATE="\$RX3_ROTATE" RX3_FONT=/usr/share/fonts/dejavu/DejaVuSans.ttf \\
    ~/rx3-fb-present ~/rx3-rootfs/dev/fb0 > /tmp/present.log 2>&1 &

sudo RX3_ROTATE="\$RX3_ROTATE" \\
    ~/rx3-touch-bridge $TOUCH_DEV ~/rx3-rootfs/dev/tsc2007_2-0048 \\
    > /tmp/touch.log 2>&1 &

sleep 2
echo "rotation:  \$RX3_ROTATE"
echo "player:    \$(pgrep -f rbp-pi | tr '\n' ' ')"
echo "presenter: \$(pgrep -f rx3-fb-present | tr '\n' ' ')"
echo "touch:     \$(pgrep -f rx3-touch-bridge | tr '\n' ' ')"
ENDOFSCRIPT
chmod +x "$HOME/rx3-up.sh"

# ---------------------------------------------------------------------------
# Step 13 — systemd service script
# ---------------------------------------------------------------------------
say "Installing /usr/local/bin/rx3-service.sh"
sudo tee /usr/local/bin/rx3-service.sh >/dev/null <<ENDOFSVC
#!/bin/bash
set -u
U=/home/user
H=\$U/Rx3-flx4/rx3-handoff
R=\$U/rx3-rootfs

case "\${1:-start}" in
  start)
    systemctl stop gdm 2>/dev/null
    sleep 1
    cd "\$H"
    ./mount-rx3.sh >/dev/null
    [ -f "\$R/etc/rx3-ctl" ] || echo "hw:0" > "\$R/etc/rx3-ctl"
    ROT=270
    [ -f "\$H/rx3.conf" ] && . "\$H/rx3.conf"

    chroot "\$R" /bin/busybox sh -c \\
      'cd /root/pdj && exec env LD_PRELOAD=/lib/fbshim.so /root/pdj/rbp-pi -a' \\
      > /tmp/player.log 2>&1 &
    sleep 5

    RX3_FB=/dev/fb0 RX3_ROTATE="\$ROT" RX3_FONT=/usr/share/fonts/dejavu/DejaVuSans.ttf \\
      "\$U/rx3-fb-present" "\$R/dev/fb0" > /tmp/present.log 2>&1 &

    RX3_ROTATE="\$ROT" \\
      "\$U/rx3-touch-bridge" $TOUCH_DEV "\$R/dev/tsc2007_2-0048" \\
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
ENDOFSVC
sudo chmod +x /usr/local/bin/rx3-service.sh

# ---------------------------------------------------------------------------
# Step 14 — systemd unit
# ---------------------------------------------------------------------------
say "Installing /etc/systemd/system/rx3.service"
sudo tee /etc/systemd/system/rx3.service >/dev/null <<'EOF'
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

# ---------------------------------------------------------------------------
# Step 15 — console boot by default (GDM must not grab DRM master)
# ---------------------------------------------------------------------------
say "Setting default target to multi-user (console, no GDM)"
sudo systemctl set-default multi-user.target

# ---------------------------------------------------------------------------
# Step 16 — udev rule for stable touch device (best effort)
# ---------------------------------------------------------------------------
say "Attempting to create stable udev symlink /dev/input/rx3-touch"
sudo mkdir -p /etc/udev/rules.d
sudo tee /etc/udev/rules.d/99-rx3-touch.rules >/dev/null <<EOF
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="$TOUCH_NAME", SYMLINK+="input/rx3-touch"
EOF
sudo udevadm control --reload-rules 2>/dev/null || true
sudo udevadm trigger --action=add --subsystem-match=input 2>/dev/null || true
sleep 1
if [ -L /dev/input/rx3-touch ]; then
    echo "    /dev/input/rx3-touch → $(readlink /dev/input/rx3-touch)"
    echo "    (scripts currently use $TOUCH_DEV; the symlink is available if you want to switch)"
else
    warn "udev symlink not created — sticking with $TOUCH_DEV. It may shuffle on reboot."
    warn "If touch stops working after a reboot, re-run this installer or re-detect manually."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<EOF

============================================================
  INSTALL COMPLETE
============================================================

Repo:        $WORKDIR
Chroot:      $ROOTFS  ($(du -sh "$ROOTFS" 2>/dev/null | cut -f1))
Rotation:    $ROTATION
Touch dev:   $TOUCH_DEV
Service:     rx3.service (enabled)
Default:     multi-user.target (console)

Next steps
----------
1. Manual launch (recommended first time):
       ~/rx3-up.sh

2. Or reboot. After ~15 s the RX3 UI should appear on the panel.

3. Service control:
       systemctl status rx3 --no-pager
       sudo systemctl restart rx3
       sudo systemctl stop rx3        # returns you to a normal console

4. Logs:
       tail -40 /tmp/player.log
       tail -40 /tmp/present.log
       tail -40 /tmp/touch.log

Notes
-----
- No audio (known limitation — the ALSA dmix slave rejects hw:0,0 with
  the firmware's requested config).
- Bind mounts do not survive reboot; the service re-runs mount-rx3.sh.
- Never run build-rootfs.sh while mount-rx3.sh mounts are active.

Full log of this install: $HOME/rx3-install.log
EOF
