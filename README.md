# XDJ-RX3 Firmware Emulation on Lenovo Duet 1

Running the Pioneer XDJ-RX3 v1.19 ARM32 firmware **natively** on a Lenovo
Duet 1 (MediaTek MT8183, `google-krane`, postmarketOS / Alpine + systemd).
The aarch64 kernel's `CONFIG_COMPAT` executes 32-bit ARM directly —
**no QEMU, no emulation**.

## What works / what doesn't

| Feature | Status |
|---|---|
| Firmware runs, UI renders (rotate 270°) | ✅ |
| Touch overlay, auto-hide 8 s, swipe-up | ✅ |
| USB hotplug (auto-mount) | ✅ |
| Deck control (`rx3-control.py` over SSH) | ✅ |
| Source switching, browsing, load/play/pause | ✅ |
| **Audio output** | ❌ needs physical DDJ-FLX4 |
| **Waveform animation** | ❌ driven by audio clock |
| **BPM / tempo / time display** | ❌ driven by audio clock |
| **Beat grid, hot cues, sync** | ❌ need audio position |

Every ❌ is the same root cause: the firmware opens
`hw:cs4344audiorev8,0/1/2` — a 4-channel I2S codec that lives inside the
**physical DDJ-FLX4**. Without it, no audio clock exists, and all
audio-derived visuals stay static. The Duet's internal mt8183 codec is
stereo-only (`CHANNELS: 2` on every PCM), so aliasing can't fake it.

The **only** fix is to connect a real DDJ-FLX4 over USB — the codec
registers as a normal ALSA card and everything comes alive with zero
code changes.

## Tested on

| Component   | Value                                   |
|-------------|-----------------------------------------|
| Device      | Lenovo Duet 1 (`google-krane`, MT8183)  |
| OS          | postmarketOS (Alpine, systemd)          |
| Kernel      | 6.18.28-mt81 (aarch64, `CONFIG_COMPAT=y`) |
| Display     | 1200×1920 DSI, `mediatekdrmfb`          |
| Rotation    | 270° clockwise                          |
| Touchscreen | `hid-over-i2c 27C6:0E30`                |
| User        | `user` (uid 10000)                      |

## Before you start

Two ZIPs must be ready on disk:

1. **XDJ-RX3 v1.19 update** — AlphaTheta support downloads
2. **Pioneer GPL source distribution** — Pioneer's open-source page

The installer pauses and asks for their paths.

## One-shot install

```bash
bash ~/rx3-duet1-install.sh 2>&1 | tee ~/rx3-install.log
```

Run as your normal user (NOT root). Idempotent — safe to re-run.

## Start / stop

```bash
# Enable + start both services
sudo systemctl enable --now rx3 rx3-pointer

# Check
systemctl status rx3 rx3-pointer --no-pager | grep -E '●|Active:'
pgrep -af 'rbp-pi|rx3-fb-present|rx3-touch-bridge'

# Logs
journalctl -u rx3 -f
journalctl -u rx3-pointer -f
tail -f ~/rx3-player.log
```

## Deck control — channel mapping

The `channel` argument is the **deck**, not a track index:

| Channel | Meaning |
|---|---|
| `0` | global (source, crossfader) |
| `1` | Deck 1 → `player0` |
| `2` | Deck 2 → `player1` |

### Basic commands

```bash
cd ~/Rx3-flx4/rx3-handoff

# Source
python3 rx3-control.py source
python3 rx3-control.py usb1

# Deck 1
python3 rx3-control.py load 1
python3 rx3-control.py play 1        # toggles play/pause
python3 rx3-control.py CUE 1
python3 rx3-control.py Sync 1

# Deck 2
python3 rx3-control.py load 2
python3 rx3-control.py play 2

# Mixer
python3 rx3-control.py ChFader 1 0.8
python3 rx3-control.py ChFader 2 0.8
python3 rx3-control.py CrossFader 0 0.5

# Query state
python3 rx3-control.py query
```

### Shell shortcuts

Add to `~/.profile`:

```bash
rx3() { cd ~/Rx3-flx4/rx3-handoff && python3 rx3-control.py "$@"; cd - >/dev/null; }
rx3-both() { rx3 play 1; rx3 play 2; }
rx3-stop() { rx3 play 1; rx3 play 2; }
```

Then: `rx3 query`, `rx3 usb1`, `rx3-both`, `rx3-stop`.

## Touch overlay

- Visible on boot; **auto-hides 8 s after last touch**
- **Swipe up** (real drag ≥ 150 px in < 900 ms) to bring it back
- Tap does not bring it back — must be a drag
- 12 on-screen buttons for transport + rotary

Tune in `~/Rx3-flx4/rx3-handoff/touch-bridge.c`:

- Auto-hide: `8000` (ms)
- Swipe: `dy>150&&dt<900`

Rebuild (note the escaped quotes for the macro):

```bash
gcc -O2 -DRX3_ROOT_PATH="\"/home/user/rx3-rootfs\"" \
    -o ~/rx3-touch-bridge ~/Rx3-flx4/rx3-handoff/touch-bridge.c
sudo systemctl restart rx3-pointer
```

## USB

**Plug in a FAT32 stick — it auto-mounts as USB1 (or USB2).**

It does **not** auto-switch source — you control when the RX3 reads from
USB instead of its internal library.

Auto-mount chain: udev `99-rx3-usb.rules` → `systemd-run` →
`usb-hotplug.sh` → `usb-attach.sh` → `rx3-control.py mount`.

Watch:

```bash
sudo journalctl -t rx3 -f
```

Expected: `usb1 attached /dev/sdb1 (mount event sent=1)`

Play from it:

```bash
cd ~/Rx3-flx4/rx3-handoff
python3 rx3-control.py source
python3 rx3-control.py usb1
python3 rx3-control.py load 1
python3 rx3-control.py play 1
```

## SSH

```bash
sudo apk add openssh
sudo systemctl enable --now sshd
sudo passwd user               # if not set
ip -4 addr show | grep inet    # get IP
```

From another machine:

```bash
ssh user@<ip>
```

Root login is disabled by default in Alpine's sshd — log in as `user`
and `sudo` from there.

## Mode switching

Installer sets boot to `multi-user.target` (console, RX3 owns the
framebuffer). To use a desktop instead:

```bash
cd ~/Rx3-flx4/rx3-handoff
./install.sh desktop
sudo apk add postmarketos-ui-phosh
sudo reboot
```

Back to RX3:

```bash
cd ~/Rx3-flx4/rx3-handoff
./install.sh
sudo systemctl enable --now rx3 rx3-pointer
```

If GNOME/GDM keeps holding the framebuffer:

```bash
sudo systemctl stop gdm
sudo systemctl restart rx3 rx3-pointer
```

## Troubleshooting

### `MISS no TrueType font` in upstream install.sh

Alpine puts DejaVu in `/usr/share/fonts/dejavu/`, upstream checks
`/usr/share/fonts/truetype/*/*.ttf`. The installer symlinks it. If it
fails:

```bash
sudo mkdir -p /usr/share/fonts/truetype
sudo ln -sfn /usr/share/fonts/dejavu /usr/share/fonts/truetype/dejavu
```

### `install: target '/etc/udev/rules.d/': No such file or directory`

```bash
sudo mkdir -p /etc/udev/rules.d
```

### `error: redefinition of 'noborder'` / `'overlay_last_touch'`

The patch script re-applied to already-patched source. Restore and rerun:

```bash
cd ~/Rx3-flx4
git checkout -- rx3-handoff/
bash ~/rx3-duet1-install.sh
```

### Overlay never auto-hides

Check the presenter got `-hidable`:

```bash
grep rx3-fb-present ~/Rx3-flx4/rx3-handoff/rx3-start.sh
# must show: rx3-fb-present -hidable $R/dev/fb0
```

Fix + restart:

```bash
sed -i 's|rx3-fb-present \$R/dev/fb0|rx3-fb-present -hidable $R/dev/fb0|' \
    ~/Rx3-flx4/rx3-handoff/rx3-start.sh
sudo systemctl restart rx3
```

### Swipe-up does not work

Watch the state file:

```bash
xxd ~/rx3-rootfs/dev/rx3-ui-state
```

Last 4 bytes: `01000000` = shown, `00000000` = hidden. Touch → should
flip to `01…`; wait 8 s → `00…`. If nothing flips, the bridge isn't
seeing touch events. Check the device it opened:

```bash
pgrep -af rx3-touch-bridge
journalctl -u rx3-pointer -n 30 --no-pager
for e in /dev/input/event*; do
  echo "$e: $(cat /sys/class/input/$(basename $e)/device/name 2>/dev/null)"
done
```

Bridge must be on the device named `hid-over-i2c 27C6:0E30`.

### USB stick doesn't auto-mount

```bash
# 1. Partition + FS
lsblk -f
sudo blkid /dev/sdb1

# 2. udev fired?
sudo journalctl -b --no-pager | grep usb-hotplug | tail

# 3. Script logged success?
sudo journalctl -t rx3 -b --no-pager | tail

# 4. Player running? (hotplug bails if not)
pgrep -af rbp-pi

# 5. Mount visible?
mount | grep sdb
ls ~/rx3-rootfs/media/usb1/
```

Expected in #3: `usb1 attached /dev/sdb1 (mount event sent=1)`.

If #2 shows the script launched but #3 is empty, the script exited
early. Most common cause was `pgrep -x rbp-pi` failing — the installer
uses `pgrep -f rbp-pi`. Verify:

```bash
grep pgrep ~/Rx3-flx4/rx3-handoff/usb-hotplug.sh
```

Should show `pgrep -f rbp-pi`.

### No audio, static waveform, no BPM

Expected — hardware limit. See the top of this README. Only a physical
DDJ-FLX4 fixes it.

The `CTL open hw:CARD=Loopback ffffffed` and `PCM open … ffffffed`
lines in `~/rx3-player.log` are harmless attempts at a fallback. The
player still runs.

### SSH hangs / refuses

```bash
systemctl status sshd --no-pager
sudo apk add openssh
sudo systemctl enable --now sshd
sudo passwd user
```

## Files

| Path | Purpose |
|---|---|
| `~/rx3-duet1-install.sh` | Installer |
| `~/Rx3-flx4/` | Upstream player repo |
| `~/Rx3-flx4/rx3-handoff/` | Patch + build scripts, patched sources |
| `~/rx3-rootfs/` | ~109 MB chroot with ARM32 firmware |
| `~/rx3-usb/` | Copy-on-write overlays for USB1/USB2 |
| `~/rx3-fb-present` | Presenter binary |
| `~/rx3-touch-bridge` | Touch bridge binary |
| `~/rx3-final/` | Backup of working sources, binaries, rules |
| `~/rx3-install.log` | Full install log |
| `~/rx3-player.log` | Player stdout/stderr |
| `/etc/systemd/system/rx3.service` | Player unit |
| `/etc/systemd/system/rx3-pointer.service` | Touch bridge unit |
| `/etc/udev/rules.d/99-rx3-usb.rules` | USB hotplug rule |
| `/etc/udev/rules.d/99-rx3-touch.rules` | Touch symlink rule |

## Restoring after a re-install

Working files are in `~/rx3-final/`:

```bash
cp ~/rx3-final/touch-bridge.c ~/rx3-final/rx3-start.sh \
   ~/rx3-final/asound.conf   ~/rx3-final/usb-hotplug.sh \
   ~/Rx3-flx4/rx3-handoff/
gcc -O2 -DRX3_ROOT_PATH="\"/home/user/rx3-rootfs\"" \
    -o ~/rx3-touch-bridge ~/Rx3-flx4/rx3-handoff/touch-bridge.c
sudo cp ~/rx3-final/99-rx3-usb.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo systemctl restart rx3 rx3-pointer
```

## Rebuilding rbp-pi from source

If `rbp-pi` gets corrupted:

```bash
sudo cp ~/Rx3-flx4/rx3-handoff/rbp-pi ~/rx3-rootfs/root/pdj/rbp-pi
sudo systemctl restart rx3
```

Or restore the last-known-good binary:

```bash
sudo cp ~/rx3-rootfs/root/pdj/rbp-pi.orig ~/rx3-rootfs/root/pdj/rbp-pi
```
```

---

**Save both files:**

```bash
nano ~/rx3-duet1-install.sh    # paste script, Ctrl+O, Enter, Ctrl+X
chmod +x ~/rx3-duet1-install.sh
nano ~/README.md               # paste readme, save
```

**One last backup of everything working:**

```bash
mkdir -p ~/rx3-final
cp ~/Rx3-flx4/rx3-handoff/touch-bridge.c ~/Rx3-flx4/rx3-handoff/rx3-start.sh ~/Rx3-flx4/rx3-handoff/asound.conf ~/Rx3-flx4/rx3-handoff/usb-hotplug.sh ~/Rx3-flx4/rx3-handoff/rbp-pi ~/rx3-final/
sudo cp /etc/udev/rules.d/99-rx3-usb.rules /etc/udev/rules.d/99-rx3-touch.rules /etc/systemd/system/rx3.service /etc/systemd/system/rx3-pointer.service ~/rx3-final/
cp ~/rx3-duet1-install.sh ~/README.md ~/rx3-final/
ls -la ~/rx3-final/
