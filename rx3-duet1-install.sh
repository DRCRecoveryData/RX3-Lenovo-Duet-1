cat > ~/rx3-duet1-pmos.sh <<'RX3_PMOS_EOF'
#!/bin/bash
# rx3-duet1-pmos.sh — Rx3-flx4 install for Lenovo Duet 1 (MT8183, google-krane)
# Target: postmarketOS / Alpine + systemd.
# Uses mainstream repo: https://github.com/mutlisensor/Rx3-flx4

set -euo pipefail

REPO="https://github.com/mutlisensor/Rx3-flx4.git"
REPO_DIR="$HOME/Rx3-flx4"
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
echo

# ------------------------------------------------------------------
# 0. System directories & USB autosuspend prevention rule
# ------------------------------------------------------------------
say "Preparing system directories and USB power rules"
sudo mkdir -p /etc/udev/rules.d /etc/systemd/system /usr/share/fonts/truetype/dejavu
sudo ln -sf /usr/share/fonts/dejavu/*.ttf /usr/share/fonts/truetype/dejavu/ 2>/dev/null || true

# Prevent FLX4 USB autosuspend disconnects
sudo tee /etc/udev/rules.d/50-flx4-power.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="2b73", ATTR{power/control}="on"
EOF
sudo udevadm control --reload-rules 2>/dev/null || true
ok "directories and power rules ready"

# ------------------------------------------------------------------
# 1. Clean previous install
# ------------------------------------------------------------------
say "Cleaning any previous install"
sudo systemctl stop  rx3 rx3-pointer rx3-bridge rx3-priv 2>/dev/null || true
sudo systemctl disable rx3 rx3-pointer 2>/dev/null || true
sudo pkill -f rbp-pi 2>/dev/null || true
sudo pkill -f rx3-fb-present 2>/dev/null || true
sudo pkill -f rx3-touch-bridge 2>/dev/null || true
sleep 1

if [ -d "$ROOT" ]; then
    for m in $(findmnt -rn -o TARGET | grep -E "^$ROOT/" | sort -r); do
        sudo umount -l "$m" 2>/dev/null || true
    done
    sudo umount -l "$ROOT" 2>/dev/null || true
fi

sudo rm -f /etc/systemd/system/rx3.service /etc/systemd/system/rx3-pointer.service
sudo systemctl daemon-reload 2>/dev/null || true
rm -rf "$ROOT" "$WORK"
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
say "Symlinking armv7 toolchain"
sudo mkdir -p /usr/local/bin
for t in gcc nm objdump strip; do
    src="/usr/bin/armv7-alpine-linux-musleabihf-${t}"
    dst="/usr/local/bin/arm-linux-gnueabi-${t}"
    [ -x "$src" ] && sudo ln -sf "$src" "$dst"
done
ok "toolchain ready"

# ------------------------------------------------------------------
# 4. Kernel uapi headers
# ------------------------------------------------------------------
say "Linking kernel uapi headers into armv7 sysroot"
SYS=/usr/armv7-alpine-linux-musleabihf/include
[ -d "$SYS" ] || die "armv7 sysroot not found at $SYS"
for h in asm asm-generic linux; do
    [ -e "/usr/include/$h" ] && sudo ln -sf "/usr/include/$h" "$SYS/$h"
done
ok "headers linked"

# ------------------------------------------------------------------
# 5. Repo + zip extraction
# ------------------------------------------------------------------
say "Fetching repo and extracting zip"
git clone "$REPO" "$REPO_DIR"

ZIP="$REPO_DIR/Rx3-flx4.zip"
[ -f "$ZIP" ] || die "Rx3-flx4.zip not found"

mkdir -p "$WORK"
unzip -o -q "$ZIP" -d "$WORK"
cd "$HANDOFF"
chmod +x *.sh
ok "extracted to $HANDOFF"

# ------------------------------------------------------------------
# 6. Patch player crash fix
# ------------------------------------------------------------------
say "Patching patch-player.py"
python3 - <<'PYEOF'
from pathlib import Path
p = Path.home() / "Rx3-flx4/rx3-handoff/patch-player.py"
s = p.read_text()
if "31df70" not in s:
    old = "(b/'rbp-pi').write_bytes(p)"
    new = "words(0x31df70,0xe3a00000)\n(b/'rbp-pi').write_bytes(p)"
    p.write_text(s.replace(old, new, 1))
PYEOF
ok "crash fix applied"

# ------------------------------------------------------------------
# 7. Configs (Rotation & Stock Audio)
# ------------------------------------------------------------------
say "Writing configurations"
cat > rx3.conf <<EOF
RX3_ROTATE=$ROTATE
RX3_FPS=30
RX3_FILTER=nearest
EOF
ok "configurations written (stock audio layout preserved)"

# ------------------------------------------------------------------
# 8. Firmware Recovery & Build Chroot
# ------------------------------------------------------------------
say "Recovering firmware and building chroot"
python3 recover-firmware.py
python3 extract_cramfs.py
./install.sh doctor || die "Fix prerequisites"
./build-rootfs.sh
ok "chroot built successfully"

# ------------------------------------------------------------------
# 9. Host Installation & Services
# ------------------------------------------------------------------
say "Running upstream install.sh"
./install.sh

sudo adduser "$(id -un)" input 2>/dev/null || sudo usermod -aG input "$(id -un)" 2>/dev/null || true

# Create touch bridge service
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
sudo systemctl enable rx3.service rx3-pointer.service
ok "services enabled"

echo "============================================================"
echo "  INSTALL COMPLETE"
echo "============================================================"
RX3_PMOS_EOF

chmod +x ~/rx3-duet1-pmos.sh
