#!/bin/bash
# rx3-duet1-install.sh — XDJ-RX3 firmware emulation on Lenovo Duet 1
# (MediaTek MT8183 / google-krane, postmarketOS / Alpine + systemd).
# Native ARM32 via CONFIG_COMPAT — no QEMU.
#
# Verified working: UI, touch overlay (auto-hide + swipe-up), USB hotplug,
# SSH, deck control via rx3-control.py.
# Not possible on this hardware: audio output, waveform animation, BPM/
# time display — all require the physical DDJ-FLX4's cs4344 codec.
#
# Run as your normal user (NOT root). Idempotent — safe to re-run.
# Usage: bash ~/rx3-duet1-install.sh 2>&1 | tee ~/rx3-install.log

set -euo pipefail

REPO="https://github.com/mutlisensor/Rx3-flx4.git"
W="$HOME/Rx3-flx4"
H="$W/rx3-handoff"
R="$HOME/rx3-rootfs"
ROT=270
TOUCH_NAME="hid-over-i2c 27C6:0E30"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. sanity ---
[ "$(id -u)" -ne 0 ] || die "Do not run as root"
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME unset"
command -v apk >/dev/null || die "apk not found — postmarketOS/Alpine required"
command -v systemctl >/dev/null || die "systemd not found"

say "Duet 1 RX3 installer"
echo "    Host: $(uname -srm)"
echo "    User: $(id -un) (uid $(id -u))"
echo "    fb:   $(cat /sys/class/graphics/fb0/name 2>/dev/null) $(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"

# --- 1. packages ---
say "Installing Alpine packages"
sudo apk add --no-cache \
    git bash build-base gcc g++ make patch linux-headers binutils \
    gcc-armv7 binutils-armv7 musl-armv7 musl-dev-armv7 libstdc++-dev-armv7 \
    fuse-overlayfs exfatprogs alsa-utils \
    py3-pillow py3-cryptography rsync 7zip \
    freetype-dev pkgconf font-dejavu libpng-dev \
    strace lsof coreutils

# --- 1b. Debian-style font path (upstream install.sh expects this) ---
say "Linking DejaVu fonts to Debian path"
sudo mkdir -p /usr/share/fonts/truetype
sudo ln -sfn /usr/share/fonts/dejavu /usr/share/fonts/truetype/dejavu
ls /usr/share/fonts/truetype/dejavu/*.ttf >/dev/null || die "no .ttf under truetype/"

# --- 1c. udev rules dir (absent on Alpine) ---
sudo mkdir -p /etc/udev/rules.d

# --- 2. armv7 toolchain symlinks ---
say "Symlinking armv7 toolchain to arm-linux-gnueabi-*"
sudo mkdir -p /usr/local/bin
for t in gcc nm objdump; do
    src="/usr/bin/armv7-alpine-linux-musleabihf-${t}"
    dst="/usr/local/bin/arm-linux-gnueabi-${t}"
    [ -x "$src" ] || die "missing $src"
    sudo ln -sf "$src" "$dst"
done
arm-linux-gnueabi-gcc --version | head -1

# --- 3. kernel uapi headers into armv7 sysroot ---
say "Symlinking kernel uapi headers into armv7 sysroot"
SYS=/usr/armv7-alpine-linux-musleabihf/include
[ -d "$SYS" ] || die "armv7 sysroot not found at $SYS"
for h in asm asm-generic linux; do
    sudo ln -sf "/usr/include/$h" "$SYS/$h"
done

# --- 4. 32-bit ARM test ---
say "Testing 32-bit ARM execution"
cat > /tmp/t32.c <<'EOF'
void _start(void){__asm__ volatile ("mov r7,#1\nmov r0,#42\nsvc #0\n");for(;;);}
EOF
armv7-alpine-linux-musleabihf-gcc -nostdlib -static -o /tmp/t32 /tmp/t32.c
set +e; /tmp/t32; rc=$?; set -e
[ "$rc" = "42" ] || die "kernel cannot run 32-bit ARM (exit=$rc)"
echo "    32-bit ARM OK"

# --- 5. clone ---
say "Cloning repo"
if [ -d "$W/.git" ]; then
    git -C "$W" pull --ff-only || warn "pull failed; using local copy"
else
    git clone "$REPO" "$W"
fi
cd "$H"
chmod +x *.sh

# --- 6. patch all C/Python source ---
say "Patching sources"

python3 - <<'PYEOF'
from pathlib import Path

H = Path.home() / "Rx3-flx4/rx3-handoff"
def edit(name, patches):
    p = H / name
    if not p.exists(): print(f"  ! {name} missing"); return
    s = p.read_text(); n = 0
    for tag, old, new in patches:
        if new in s:
            n += 1; continue           # idempotent
        if old in s:
            s = s.replace(old, new, 1); n += 1
        else:
            print(f"    MISS: {name}:{tag}")
    p.write_text(s)
    print(f"  {name}: {n}/{len(patches)}")

# patch-player.py: getPcController NULL fix
p = H / "patch-player.py"
if p.exists():
    s = p.read_text()
    if "31df70" not in s:
        old = "(b/'rbp-pi').write_bytes(p)"
        new = "words(0x31df70,0xe3a00000)\n(b/'rbp-pi').write_bytes(p)"
        if old in s: p.write_text(s.replace(old, new, 1)); print("  patch-player.py: patched")
    else: print("  patch-player.py: already patched")

# build-rootfs.sh: Alpine sysroot + apk
p = H / "build-rootfs.sh"
if p.exists():
    s = p.read_text()
    s = s.replace("arm-linux-gnueabi-gcc -shared -fPIC",
                  "arm-linux-gnueabi-gcc --sysroot=/usr/armv7-alpine-linux-musleabihf -shared -fPIC")
    s = s.replace("apt install gcc-arm-linux-gnueabi", "apk add gcc-armv7 musl-dev-armv7")
    p.write_text(s); print("  build-rootfs.sh: patched")

# control-shim.c
edit("control-shim.c", [
    ("gate_thread",
     "static void *control_thread(void *unused){\n sleep(3);",
     ("static volatile void *g_manager = 0;\n"
      "static void refresh_manager(void){\n"
      " void *m=0;void *root=*(void *volatile *)0x026867c0;\n"
      " if(root)m=*(void **)((char*)root+0x64);\n"
      " if(m){((void (*)(void*,int))0x37c8d8)(m,3);g_manager=m;}\n"
      "}\n"
      "static void *gate_thread(void *unused){\n sleep(5);\n"
      " for(;;){refresh_manager();sleep(10);}\n return 0;}\n"
      "static void *control_thread(void *unused){\n sleep(3);")),
    ("gate_spawn",
     " ((void (*)(void*,int))0x37c8d8)(manager,3);\n void (*sendkey)",
     (" ((void (*)(void*,int))0x37c8d8)(manager,3);\n"
      " unsigned long t2;pthread_create(&t2,0,gate_thread,0);\n void (*sendkey)")),
    ("refresh_loop",
     "  sendkey(manager,c.key,c.operation,c.channel,c.value,c.analog,c.extra);",
     ("  refresh_manager();\n"
      "  void *m=g_manager?g_manager:manager;\n"
      "  sendkey(m,c.key,c.operation,c.channel,c.value,c.analog,c.extra);")),
])

# pi-controls.h
edit("pi-controls.h", [
    ("overlay_visible",
     "int cursor_x,cursor_y,cursor_visible;};",
     "int cursor_x,cursor_y,cursor_visible;int overlay_visible;};"),
])

# fb-present.c — -hidable flag + border toggle
edit("fb-present.c", [
    ("flag_parse",
     " if(argc<2)return 2;\n const char*fbpath=argc>2?argv[2]:fb_device();",
     (" int noborder=0,hidable=0;\n"
      " while(argc>1&&argv[1][0]=='-'){\n"
      "  if(!strcmp(argv[1],\"-noborder\")){noborder=1;argc--;argv++;continue;}\n"
      "  if(!strcmp(argv[1],\"-hidable\")){hidable=1;argc--;argv++;continue;}\n"
      "  break;}\n"
      " if(argc<2)return 2;\n const char*fbpath=argc>2?argv[2]:fb_device();")),
    ("loop_header",
     (" for(;;){\n memcpy(frame,chrome,sizeof(frame));\n"
      " for(int y=0;y<1000;y++){int sy=y*4/5;for(int x=0;x<1600;x++)frame[y*1920+x+160]=s[sy*1280+x*4/5];}\n"),
     (" int _lb=-1;\n for(;;){\n"
      " int draw_border = !noborder && (!hidable || state->overlay_visible);\n"
      " if(draw_border!=_lb){\n"
      "  if(draw_border){for(int py=0;py<H;py++)for(int px=0;px<W;px++){int cx,cy;idx[py*W+px]=panel_to_canvas(&L,px,py,0,&cx,&cy)?cy*1920+cx:-1;}}\n"
      "  else{for(int py=0;py<H;py++)for(int px=0;px<W;px++){int su=px*1200/W,sv=py*1920/H;int cx,cy;\n"
      "   switch(L.rot){case 90:cx=sv;cy=1199-su;break;case 180:cx=1919-su;cy=1199-sv;break;case 270:cx=1919-sv;cy=su;break;default:cx=su;cy=sv;}\n"
      "   if(cx<0)cx=0;if(cx>1919)cx=1919;if(cy<0)cy=0;if(cy>1199)cy=1199;idx[py*W+px]=cy*1920+cx;}}\n"
      "  _lb=draw_border;}\n"
      " if(draw_border)memcpy(frame,chrome,sizeof(frame));else memset(frame,0,sizeof(frame));\n"
      " if(draw_border){for(int y=0;y<1000;y++){int sy=y*4/5;for(int x=0;x<1600;x++)frame[y*1920+x+160]=s[sy*1280+x*4/5];}}\n"
      " else{for(int y=0;y<1200;y++){int sy=y*2/3;for(int x=0;x<1920;x++)frame[y*1920+x]=s[sy*1280+x*2/3];}}\n")),
    ("button_open",
     " for(int i=0;i<12;i++)if(state->pressed&(1u<<i))drawbutton(i,1);\n",
     " if(draw_border){\n for(int i=0;i<12;i++)if(state->pressed&(1u<<i))drawbutton(i,1);\n"),
    ("button_close",
     ' char val[24];snprintf(val,sizeof(val),"%d%%",(int)(n*100+.5));label(x+80,y+305,val,25,0xd1dae2);}\n',
     ' char val[24];snprintf(val,sizeof(val),"%d%%",(int)(n*100+.5));label(x+80,y+305,val,25,0xd1dae2);}\n }\n'),
])

# touch-bridge.c — swipe-up + auto-hide (relaxed threshold)
edit("touch-bridge.c", [
    ("struct",
     "struct finger {int x,y,down,active,region;long next_repeat;};",
     "struct finger {int x,y,down,active,region;long next_repeat;long t_start;int y_start,y_min,y_max;};"),
    ("global",
     "static long millis(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000+t.tv_nsec/1000000;}",
     "static long millis(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000+t.tv_nsec/1000000;}\nstatic long overlay_last_touch=0;"),
    ("state_init",
     " if(state->magic!=0x52583332)*state=(struct ui_state){0x52583332,{1,.6,0,1,.5,.5},0,1};",
     " if(state->magic!=0x52583332)*state=(struct ui_state){0x52583332,{1,.6,0,1,.5,.5},0,1};\n state->overlay_visible=1;overlay_last_touch=millis();"),
    ("finger_down",
     "  if(f->down&&!f->active){f->active=1;f->region=-1;",
     "  if(f->down&&!f->active){f->active=1;f->region=-1;f->t_start=now;f->y_start=ly;f->y_min=ly;f->y_max=ly;"),
    ("track",
     "   else if(f->region==0){ux=(lx-160)*4/5;uy=ly*4/5;if(ux<0)ux=0;if(ux>1279)ux=1279;if(uy<0)uy=0;if(uy>799)uy=799;}\n",
     "   else if(f->region==0){ux=(lx-160)*4/5;uy=ly*4/5;if(ux<0)ux=0;if(ux>1279)ux=1279;if(uy<0)uy=0;if(uy>799)uy=799;}\n   if(ly<f->y_min)f->y_min=ly;if(ly>f->y_max)f->y_max=ly;\n"),
    ("release",
     "  if(f->active&&!f->down){if(f->region>0&&f->region<=12)button(f->region-1,0);if(source==i){source=-1;release=10;}f->active=0;}",
     ("  if(f->active&&!f->down){if(f->region>0&&f->region<=12)button(f->region-1,0);if(source==i){source=-1;release=10;}"
      "int dy=f->y_max-f->y_min;int dt=(int)(now-f->t_start);"
      "if(dy>150&&dt<900){state->overlay_visible=1;overlay_last_touch=now;}f->active=0;}")),
    ("timer",
     " long now=millis();\n for(int i=0;i<10;i++){",
     (" long now=millis();\n"
      " {int anydown=0;for(int i=0;i<10;i++)if(fingers[i].down){anydown=1;break;}\n"
      "  if(anydown&&state->overlay_visible)overlay_last_touch=now;\n"
      "  if(state->overlay_visible&&overlay_last_touch&&(now-overlay_last_touch)>8000)state->overlay_visible=0;}\n"
      " for(int i=0;i<10;i++){")),
])

# rx3-control.py: op=0 for Duet
p = H / "rx3-control.py"
if p.exists():
    s = p.read_text()
    if "send(k,1,ch)" in s:
        s = s.replace("send(k,1,ch)", "send(k,0,ch)", 1); p.write_text(s)
        print("  rx3-control.py: op=1 -> op=0")
    else: print("  rx3-control.py: op=0 already")

# usb-attach.sh: mknod hex->decimal
edit("usb-attach.sh", [
    ("mknod",
     'mknod $R/dev/$PART b 0x$(stat -c %t "$SRC") 0x$(stat -c %T "$SRC")',
     'mknod $R/dev/$PART b $((16#$(stat -c %t "$SRC"))) $((16#$(stat -c %T "$SRC")))'),
])

# usb-hotplug.sh: pgrep fix + mount retry
p = H / "usb-hotplug.sh"
if p.exists():
    if not (H / "usb-hotplug.sh.orig").exists():
        (H / "usb-hotplug.sh.orig").write_text(p.read_text())
    s = p.read_text()
    if "pgrep -x rbp-pi" in s:
        s = s.replace("pgrep -x rbp-pi", "pgrep -f rbp-pi", 1)
        print("  usb-hotplug.sh: pgrep -x -> pgrep -f")
    if "mount event sent" not in s:
        old = '''    $H/usb-attach.sh "$DEV" $PORT 9>&- && sudo -u $RX3_USER python3 $H/rx3-control.py mount $PORT /media/$PORT/$PART 9>&-
    logger -t rx3 "$PORT attached $DEV" ;;'''
        new = '''    if $H/usb-attach.sh "$DEV" $PORT 9>&-; then
        ok=0
        for i in $(seq 1 15); do
            if sudo -u "$RX3_USER" python3 $H/rx3-control.py mount $PORT /media/$PORT/$PART 9>&-; then
                ok=1; break
            fi
            sleep 1
        done
        logger -t rx3 "$PORT attached $DEV (mount event sent=$ok)"
    else
        logger -t rx3 "$PORT usb-attach FAILED"
    fi ;;'''
        if old in s:
            s = s.replace(old, new, 1); print("  usb-hotplug.sh: mount retry patched")
    else: print("  usb-hotplug.sh: already patched")
    p.write_text(s)

print("  all source patches done")
PYEOF

# --- 7. firmware recovery ---
if [ -f "$H/runtime-symlinks.json" ]; then
    say "Firmware already extracted"
else
    say "Recovering firmware (interactive)"
    warn "Have XDJ-RX3 v1.19 update + Pioneer GPL source .zip ready"
    python3 recover-firmware.py || die "recover-firmware.py failed"
    python3 extract_cramfs.py 2>&1 | tee /tmp/extract.log
    grep -q "Extraction complete." /tmp/extract.log || die "extract_cramfs.py incomplete"
fi

# --- 8. build chroot ---
say "Building chroot"
if [ -f "$R/etc/rx3-ctl" ] && [ -d "$R/root/pdj" ]; then
    echo "    already built"
else
    for m in $(mount | awk -v r="$R" 'index($3,r)==1{print $3}' | sort -r); do
        sudo umount -l "$m" 2>/dev/null || sudo umount -f "$m" 2>/dev/null || true
    done
    ./build-rootfs.sh 2>&1 | tee /tmp/build.log
    grep -q '^== done' /tmp/build.log || die "build-rootfs.sh failed"
fi
say "    size: $(du -sh "$R" 2>/dev/null | cut -f1)"

# --- 9. runtime files ---
say "Writing chroot runtime files"
echo "hw:0" | sudo tee "$R/etc/rx3-ctl" >/dev/null
sudo cp "$H/asound.conf" "$R/etc/asound.conf"

# --- 10. device binds for the chroot ---
say "Binding /proc/asound and /dev/snd into the chroot"
sudo mkdir -p "$R/proc/asound" "$R/dev/snd"
mountpoint -q "$R/proc/asound" || sudo mount --bind /proc/asound "$R/proc/asound"
mountpoint -q "$R/dev/snd"     || sudo mount --bind /dev/snd     "$R/dev/snd"

# --- 11. compile host helpers ---
say "Compiling presenter + touch bridge"
gcc -O2 -DRX3_ROOT_PATH="\"$R\"" $(pkg-config --cflags freetype2) \
    -o "$HOME/rx3-fb-present" fb-present.c $(pkg-config --libs freetype2) || die "fb-present.c failed"
gcc -O2 -DRX3_ROOT_PATH="\"$R\"" -o "$HOME/rx3-touch-bridge" touch-bridge.c || die "touch-bridge.c failed"

for b in "$HOME/rx3-fb-present" "$HOME/rx3-touch-bridge"; do
    got=$(strings "$b" | grep -m1 'ui-state' || true)
    case "$got" in "$R"*) echo "    $b ok";; *) die "$b wrong path: $got";; esac
done

# --- 12. rotation ---
say "Writing rx3.conf (RX3_ROTATE=$ROT)"
echo "RX3_ROTATE=$ROT" > "$H/rx3.conf"

# --- 13. upstream install.sh ---
say "Running upstream install.sh"
./install.sh || die "install.sh failed"
sudo systemctl daemon-reload
sudo systemctl enable rx3.service 2>/dev/null || true

# --- 13b. -hidable on the presenter ---
say "Enabling -hidable on the presenter"
S="$H/rx3-start.sh"
if [ -f "$S" ] && ! grep -q 'rx3-fb-present -hidable' "$S"; then
    sed -i 's|rx3-fb-present \$R/dev/fb0|rx3-fb-present -hidable $R/dev/fb0|' "$S"
    echo "    patched"
else echo "    already patched"; fi

# --- 14. touch bridge service ---
say "Installing rx3-pointer.service"

BY=""
for p in /dev/input/by-path/*event*; do
    [ -e "$p" ] || continue
    tgt="/sys/class/input/$(basename $(readlink -f "$p"))/device/name"
    n=$(cat "$tgt" 2>/dev/null || true)
    [ "$n" = "$TOUCH_NAME" ] && { BY="$p"; break; }
done
[ -n "$BY" ] && echo "    touch by-path: $BY"

sudo tee /etc/systemd/system/rx3-pointer.service >/dev/null <<EOF
[Unit]
Description=RX3 touch bridge (swipe-up overlay)
After=rx3.service

[Service]
Type=simple
User=root
Environment=RX3_FB=/dev/fb0
Environment=RX3_ROTATE=$ROT
ExecStart=/bin/bash -c 'for i in \$(seq 1 60); do for e in /dev/input/event*; do n=\$(cat /sys/class/input/\$(basename \$e)/device/name 2>/dev/null); if [ "\$n" = "$TOUCH_NAME" ]; then exec $HOME/rx3-touch-bridge "\$e" $R/dev/tsc2007_2-0048; fi; done; sleep 2; done; exit 1'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# --- 15. udev rules ---
sudo mkdir -p /etc/udev/rules.d
sudo tee /etc/udev/rules.d/99-rx3-touch.rules >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_TOUCHSCREEN}=="1", SYMLINK+="input/rx3-touch"
EOF
sudo udevadm control --reload-rules 2>/dev/null || true
sudo udevadm trigger --action=add --subsystem-match=input 2>/dev/null || true

sudo systemctl daemon-reload
sudo systemctl enable rx3-pointer.service

# --- 16. backup ---
say "Saving working config to ~/rx3-final/"
mkdir -p "$HOME/rx3-final"
cp "$H/pi-controls.h" "$H/fb-present.c" "$H/touch-bridge.c" \
   "$H/control-shim.c" "$H/rx3-control.py" "$H/usb-attach.sh" \
   "$H/usb-hotplug.sh" "$H/rx3.conf" "$H/rx3-start.sh" "$H/asound.conf" \
   "$HOME/rx3-final/" 2>/dev/null || true
cp "$HOME/rx3-fb-present" "$HOME/rx3-touch-bridge" "$HOME/rx3-final/"
cp /etc/systemd/system/rx3.service /etc/systemd/system/rx3-pointer.service \
   /etc/udev/rules.d/99-rx3-touch.rules /etc/udev/rules.d/99-rx3-usb.rules \
   "$HOME/rx3-final/" 2>/dev/null || true

# --- 17. done ---
cat <<EOF

============================================================
  INSTALL COMPLETE  (Lenovo Duet 1)
============================================================

  Repo:      $W
  Chroot:    $R  ($(du -sh "$R" 2>/dev/null | cut -f1))
  Presenter: $HOME/rx3-fb-present     (-hidable, rotation $ROT)
  Touch:     $HOME/rx3-touch-bridge   (swipe-up overlay, rotation $ROT)
  Backup:    $HOME/rx3-final/
  Services:  rx3.service, rx3-pointer.service (both enabled)

Next steps
----------
1. Start:
       sudo systemctl enable --now rx3 rx3-pointer

2. Check:
       systemctl status rx3 rx3-pointer --no-pager | grep -E '●|Active:'
       pgrep -af 'rbp-pi|rx3-fb-present|rx3-touch-bridge'

3. Overlay visible on boot; auto-hides 8 s after last touch.
   Swipe up (real drag >= 150 px) to bring it back.

4. Deck control (works over SSH):
       cd $H
       python3 rx3-control.py query
       python3 rx3-control.py load 1 && python3 rx3-control.py play 1
       python3 rx3-control.py load 2 && python3 rx3-control.py play 2

   Channel mapping:
       1 -> Deck 1 (player0)
       2 -> Deck 2 (player1)
       0 -> global (source, crossfader)

5. USB: plug in a FAT32 stick — it auto-mounts as USB1.
   Does NOT auto-switch source. To play from it:
       python3 rx3-control.py source
       python3 rx3-control.py usb1
       python3 rx3-control.py load 1 && python3 rx3-control.py play 1

Mode switch
-----------
  To desktop:   cd $H && ./install.sh desktop
  Back to RX3:  cd $H && ./install.sh && sudo systemctl enable --now rx3 rx3-pointer

Known limits (hardware, cannot be fixed in software):
  - Audio output: firmware needs cs4344audiorev8 codec — only present
    on a physical DDJ-FLX4. Duet's internal codec is stereo-only.
  - Waveform animation, BPM/tempo display, time counter: all driven
    by the audio clock, so they stay static without the codec.
  - op=0 for buttons on the Duet; op=1 corrupts the mixer.

Full log: $HOME/rx3-install.log
EOF
