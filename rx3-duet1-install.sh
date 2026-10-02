cat > ~/rx3-duet1-pmos.sh <<'RX3_PMOS_EOF'
#!/bin/bash
# rx3-duet1-pmos.sh — Rx3-flx4 install for Lenovo Duet 1 (MT8183, google-krane)
# Target: postmarketOS / Alpine + systemd.
#
# Uses the newer Rx3-flx4.zip from DRCRecoveryData/rx3-pi4-7inch.
# Run as your normal user (NOT root). Idempotent.

set -euo pipefail

REPO="https://github.com/DRCRecoveryData/rx3-pi4-7inch.git"
REPO_DIR="$HOME/rx3-pi4-7inch"
WORK="$HOME/Rx3-flx4"
HANDOFF="$WORK/rx3-handoff"
ROOT="$HOME/rx3-rootfs"
TOUCH_NAME="hid-over-i2c 27C6:0E30"
ROTATE=270

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '    \033[1;32mok\033[0m %s\n' "$*"; }

[ "$(id -u)" -ne 0 ] || die "Do not run as root."
command -v apk     >/dev/null || die "apk not found — postmarketOS/Alpine required."
command -v systemctl >/dev/null || die "systemd not found."

echo "============================================================"
echo "  Rx3-flx4 for Duet 1 (postmarketOS / Alpine)"
echo "============================================================"
echo "  Host: $(uname -srm)"
echo "  User: $(id -un) (uid $(id -u))"
echo "  fb:   $(cat /sys/class/graphics/fb0/name 2>/dev/null) $(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
echo

# ------------------------------------------------------------------
# 1. Clean previous install (safe to skip if none exists)
# ------------------------------------------------------------------
say "Cleaning any previous install"

sudo systemctl stop  rx3 rx3-pointer rx3-bridge rx3-priv 2>/dev/null || true
sudo systemctl disable rx3 rx3-pointer 2>/dev/null || true
sudo pkill -f rbp-pi 2>/dev/null || true
sudo pkill -f rx3-fb-present 2>/dev/null || true
sudo pkill -f rx3-touch-bridge 2>/dev/null || true
sudo pkill -f controller-bridge 2>/dev/null || true
sleep 1

if [ -d "$ROOT" ]; then
    for m in $(findmnt -rn -o TARGET | grep -E "^$ROOT/" | sort -r); do
        sudo umount -l "$m" 2>/dev/null || true
    done
    sudo umount -l "$ROOT" 2>/dev/null || true
fi

sudo rm -f /etc/systemd/system/rx3.service
sudo rm -f /etc/systemd/system/rx3-pointer.service
sudo rm -f /etc/udev/rules.d/97-rx3-input.rules
sudo rm -f /etc/udev/rules.d/98-rx3-controller.rules
sudo rm -f /etc/udev/rules.d/98-rx3-flx4.rules
sudo rm -f /etc/udev/rules.d/99-rx3-usb.rules
sudo rm -f /etc/udev/rules.d/99-rx3-touch.rules
sudo systemctl daemon-reload 2>/dev/null || true
sudo udevadm control --reload-rules 2>/dev/null || true

rm -rf "$ROOT" "$HOME/rx3-usb" "$HOME/rx3-fb-present" "$HOME/rx3-touch-bridge"
rm -f  "$HOME/rx3-player.log" "$HOME/rx3-controller.log" "$HOME/rx3-present.log" "$HOME/rx3-touch.log" "$HOME/rx3-usb.log"
# Keep $WORK if you want to reuse; delete for a fully clean start:
# rm -rf "$WORK"

ok "previous install removed"

# ------------------------------------------------------------------
# 2. Packages
# ------------------------------------------------------------------
say "Installing Alpine packages"

sudo apk update
sudo apk add --no-cache \
    git bash build-base gcc g++ make patch linux-headers binutils \
    gcc-armv7 binutils-armv7 musl-armv7 musl-dev-armv7 libstdc++-dev-armv7 \
    fuse-overlayfs exfatprogs alsa-utils \
    py3-pillow py3-cryptography rsync 7zip unzip curl \
    freetype-dev pkgconf font-dejavu libpng-dev \
    strace lsof coreutils evtest

ok "packages installed"

# ------------------------------------------------------------------
# 3. armv7 toolchain symlinks
# ------------------------------------------------------------------
say "Symlinking armv7 toolchain to arm-linux-gnueabi-*"

sudo mkdir -p /usr/local/bin
for t in gcc nm objdump strip; do
    src="/usr/bin/armv7-alpine-linux-musleabihf-${t}"
    dst="/usr/local/bin/arm-linux-gnueabi-${t}"
    [ -x "$src" ] || warn "missing $src"
    [ -x "$src" ] && sudo ln -sf "$src" "$dst"
done
arm-linux-gnueabi-gcc --version | head -1 || die "toolchain symlink failed"
ok "toolchain ready"

# ------------------------------------------------------------------
# 4. kernel uapi headers for the armv7 sysroot
# ------------------------------------------------------------------
say "Linking kernel uapi headers into armv7 sysroot"

SYS=/usr/armv7-alpine-linux-musleabihf/include
[ -d "$SYS" ] || die "armv7 sysroot not found at $SYS"
for h in asm asm-generic linux; do
    [ -e "/usr/include/$h" ] && sudo ln -sf "/usr/include/$h" "$SYS/$h"
done
ok "headers linked"

# ------------------------------------------------------------------
# 5. 32-bit ARM test
# ------------------------------------------------------------------
say "Testing 32-bit ARM execution"
cat > /tmp/t32.c <<'EOF'
void _start(void){__asm__ volatile ("mov r7,#1\nmov r0,#42\nsvc #0\n");for(;;);}
EOF
arm-linux-gnueabi-gcc -nostdlib -static -o /tmp/t32 /tmp/t32.c
set +e; /tmp/t32; rc=$?; set -e
[ "$rc" = "42" ] || die "kernel cannot run 32-bit ARM (exit=$rc). Enable CONFIG_COMPAT."
ok "32-bit ARM OK"

# ------------------------------------------------------------------
# 6. Repo + zip
# ------------------------------------------------------------------
say "Fetching repo and extracting zip"

if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" pull --ff-only || warn "pull failed; using local copy"
else
    git clone "$REPO" "$REPO_DIR"
fi

ZIP="$REPO_DIR/Rx3-flx4.zip"
[ -f "$ZIP" ] || die "Rx3-flx4.zip not found in $REPO_DIR"

rm -rf "$WORK"
mkdir -p "$WORK"
unzip -o -q "$ZIP" -d "$WORK"

# The zip contains Rx3-flx4/... — flatten into $WORK so paths match upstream
if [ -d "$WORK/Rx3-flx4" ] && [ ! -d "$WORK/rx3-handoff" ]; then
    mv "$WORK/Rx3-flx4"/* "$WORK/" 2>/dev/null || true
    mv "$WORK/Rx3-flx4"/.[!.]* "$WORK/" 2>/dev/null || true
    rmdir "$WORK/Rx3-flx4" 2>/dev/null || true
fi

[ -d "$HANDOFF" ] || die "rx3-handoff not found in extracted zip"
cd "$HANDOFF"
chmod +x *.sh
ok "extracted to $HANDOFF"

# ------------------------------------------------------------------
# 7. Add the 0x31df70 crash fix to patch-player.py
# ------------------------------------------------------------------
say "Patching patch-player.py (adding 0x31df70 fix)"

python3 - <<'PYEOF'
from pathlib import Path
p = Path.home() / "Rx3-flx4/rx3-handoff/patch-player.py"
s = p.read_text()
if "31df70" in s:
    print("    already present")
else:
    old = "(b/'rbp-pi').write_bytes(p)"
    new = "words(0x31df70,0xe3a00000)\n(b/'rbp-pi').write_bytes(p)"
    if old in s:
        p.write_text(s.replace(old, new, 1))
        print("    added words(0x31df70,0xe3a00000)")
    else:
        raise SystemExit("MISS: write_bytes line not found in patch-player.py")
PYEOF
grep -n '31df70' patch-player.py
ok "crash fix present"

# ------------------------------------------------------------------
# 8. Duet-specific rx3.conf
# ------------------------------------------------------------------
say "Writing rx3.conf for Duet panel"
cat > rx3.conf <<EOF
RX3_ROTATE=$ROTATE
RX3_FPS=30
RX3_FILTER=nearest
EOF
cat rx3.conf
ok "rx3.conf written"

# ------------------------------------------------------------------
# 9. Firmware recovery
# ------------------------------------------------------------------
if [ -f "$HANDOFF/runtime-symlinks.json" ]; then
    say "Firmware already recovered"
else
    say "Recovering firmware"
    warn "Have XDJ-RX3 v1.19 update + GPL source zips ready"
    python3 recover-firmware.py
    python3 extract_cramfs.py 2>&1 | tee /tmp/extract.log
    grep -q "Extraction complete." /tmp/extract.log || die "extract_cramfs.py incomplete"
fi
ok "firmware ready"

# ------------------------------------------------------------------
# 10. Doctor
# ------------------------------------------------------------------
say "Prerequisite check"
./install.sh doctor || die "fix prerequisites, then re-run"

# ------------------------------------------------------------------
# 11. Build chroot
# ------------------------------------------------------------------
say "Building chroot"
./build-rootfs.sh 2>&1 | tee /tmp/build.log
grep -q '^== done' /tmp/build.log || die "build-rootfs.sh failed"

# Verify the crash fix landed in the chroot binary
python3 - <<PYEOF
from pathlib import Path
b = Path("$ROOT/root/pdj/rbp-pi").read_bytes()
w = int.from_bytes(b[0x315f70:0x315f74], "little")
print("    0x315f70 =", hex(w), "OK" if w == 0xe3a00000 else "NOT PATCHED")
if w != 0xe3a00000:
    raise SystemExit("crash fix missing from chroot binary")
PYEOF

# ------------------------------------------------------------------
# 12. Tune asound.conf for the Duet's slow CPU (avoids cue underrun)
# ------------------------------------------------------------------
say "Tuning asound.conf buffer sizes"
sed -i 's/period_size 128/period_size 1024/; s/buffer_size 512/buffer_size 8192/' "$HANDOFF/asound.conf"
grep -E 'period_size|buffer_size' "$HANDOFF/asound.conf"
# Apply to chroot copy if the build already placed one
[ -f "$ROOT/etc/asound.conf" ] && sudo sed -i 's/period_size 128/period_size 1024/; s/buffer_size 512/buffer_size 8192/' "$ROOT/etc/asound.conf" || true
ok "buffer sizes updated"

# ------------------------------------------------------------------
# 13. Host install (builds helpers, installs service, udev, cursor, PipeWire mask)
# ------------------------------------------------------------------
say "Running upstream install.sh"
./install.sh 2>&1 | tee /tmp/install.log
ok "host install complete"

# ------------------------------------------------------------------
# 14. Add user to input group (needed for the touch bridge)
# ------------------------------------------------------------------
say "Adding $(id -un) to 'input' group"
sudo adduser "$(id -un)" input 2>/dev/null || sudo usermod -aG input "$(id -un)" 2>/dev/null || true
id "$(id -un)" | grep -q input && ok "in input group" || warn "group change requires logout to take effect"
# Make the current session pick up the group too
sg input -c 'true' 2>/dev/null || true

# ------------------------------------------------------------------
# 15. rx3-pointer.service (the new zip doesn't install one)
# ------------------------------------------------------------------
say "Creating rx3-pointer.service for the Duet touchscreen"

sudo tee /etc/systemd/system/rx3-pointer.service >/dev/null <<EOF
[Unit]
Description=RX3 touch bridge (Duet 1 hid-over-i2c panel)
After=rx3.service
BindsTo=rx3.service

[Service]
Type=simple
User=root
ExecStart=/bin/bash -c 'for i in \$(seq 1 60); do for e in /dev/input/event*; do n=\$(cat /sys/class/input/\$(basename \$e)/device/name 2>/dev/null); if [ "\$n" = "$TOUCH_NAME" ]; then exec $HOME/rx3-touch-bridge "\$e" $ROOT/dev/tsc2007_2-0048; fi; done; sleep 2; done; exit 1'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable rx3-pointer.service
ok "rx3-pointer.service installed"

# ------------------------------------------------------------------
# 16. Enable rx3 service
# ------------------------------------------------------------------
say "Enabling rx3.service"
sudo systemctl enable rx3.service
ok "rx3.service enabled"

# ------------------------------------------------------------------
# 17. Done
# ------------------------------------------------------------------
cat <<EOF

============================================================
  INSTALL COMPLETE  (Lenovo Duet 1, postmarketOS)
============================================================

  Repo:      $WORK
  Chroot:    $ROOT  ($(du -sh "$ROOT" 2>/dev/null | cut -f1))
  Presenter: $HOME/rx3-fb-present
  Touch:     $HOME/rx3-touch-bridge   ($TOUCH_NAME)
  Config:    $HANDOFF/rx3.conf        (rotate=$ROTATE fps=30 filter=nearest)
  Services:  rx3.service, rx3-pointer.service (both enabled)

Start now (no reboot needed):
  sudo systemctl start rx3
  sleep 15
  sudo systemctl start rx3-pointer

Check:
  systemctl status rx3 rx3-pointer --no-pager | grep -E 'Active|●'
  pgrep -af 'rbp-pi|rx3-fb-present|rx3-touch-bridge'

If touch doesn't respond, log out and back in (or reboot) so the
'input' group takes effect for your session, then:

  sudo systemctl restart rx3 rx3-pointer

Logs:
  journalctl -u rx3 -f
  tail -f ~/rx3-player.log
  tail -f ~/rx3-touch.log
EOF

RX3_PMOS_EOF

chmod +x ~/rx3-duet1-pmos.sh
