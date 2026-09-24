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
| `0` | global (source, crossfader, master) |
| `1` | Deck 1 → `player0` |
| `2` | Deck 2 → `player1` |

**All key names are lowercase.** `CUE` fails; `cue` works.

### Complete keymap

**Transport (per deck — add channel 1 or 2):**

```bash
python3 rx3-control.py play 1        # toggle play/pause
python3 rx3-control.py cue 1         # cue point
python3 rx3-control.py sync 1        # sync to master
python3 rx3-control.py loopin 1      # set loop in
python3 rx3-control.py loopout 1     # set loop out
python3 rx3-control.py reloop 1      # reloop / exit loop
python3 rx3-control.py hotcue 1      # enter hot cue mode
python3 rx3-control.py beatloop 1
python3 rx3-control.py beatjump 1
python3 rx3-control.py slip 1
python3 rx3-control.py quantize 1
python3 rx3-control.py vinyl 1
python3 rx3-control.py mastertempo 1
python3 rx3-control.py jog 1         # jog wheel
python3 rx3-control.py jogtouch 1
python3 rx3-control.py trackfwd 1    # next track
python3 rx3-control.py trackrev 1    # previous track
python3 rx3-control.py deckselect 1
python3 rx3-control.py load 1        # load selected track
python3 rx3-control.py shift 1       # shift modifier
```

**Pads (per deck):**

```bash
python3 rx3-control.py pad1 1
python3 rx3-control.py pad2 1
# ... pad3 through pad8
```

**Source / library:**

```bash
python3 rx3-control.py source        # toggle source menu
python3 rx3-control.py usb1          # switch to USB1
python3 rx3-control.py usb2          # switch to USB2
python3 rx3-control.py browse        # enter browse mode
python3 rx3-control.py playlist
python3 rx3-control.py search
python3 rx3-control.py menu
python3 rx3-control.py enter         # confirm selection
python3 rx3-control.py back          # go back
python3 rx3-control.py info
python3 rx3-control.py usbstop       # safely stop USB
```

**Mixer (channel = deck 1 or 2):**

```bash
python3 rx3-control.py fader 1 0.8         # channel fader 0..1
python3 rx3-control.py trim 1 0.5          # trim / gain
python3 rx3-control.py eqh 1 0.5           # EQ high
python3 rx3-control.py eqm 1 0.5           # EQ mid
python3 rx3-control.py eql 1 0.5           # EQ low
python3 rx3-control.py color 1 0.5         # colour FX knob
python3 rx3-control.py headphones 1 1      # headphone cue toggle
```

**Master / crossfader (channel 0):**

```bash
python3 rx3-control.py cross 0 0.5         # crossfader
python3 rx3-control.py masterlv 0 0.8      # master level
python3 rx3-control.py hpmix 0 0.5         # headphone mix
python3 rx3-control.py hpcue 0 1           # master cue
python3 rx3-control.py master 0 1
```

**Rotary / browse selector:**

```bash
python3 rx3-control.py rotary +1           # next track
python3 rx3-control.py rotary -1           # prev track
python3 rx3-control.py rotary +5
```

**Raw hex codes** — always work, never case-sensitive. From
`~/rx3-rootfs/tmp/rx3-keycodes.txt`:

```bash
python3 rx3-control.py 0x4101 1    # Play/Pause on deck 1
python3 rx3-control.py 0x4102 1    # CUE on deck 1
python3 rx3-control.py 0x4311 1    # Load on deck 1
python3 rx3-control.py 0x4103 1    # Shift on deck 1
python3 rx3-control.py 0x420c 0    # Rotary selector (global)
```

### Full workflow — load and play both decks

```bash
cd ~/Rx3-flx4/rx3-handoff

# switch to USB
python3 rx3-control.py source
python3 rx3-control.py usb1
sleep 1

# browse and load
python3 rx3-control.py rotary +1
python3 rx3-control.py load 1
python3 rx3-control.py rotary +1
python3 rx3-control.py load 2

# play both
python3 rx3-control.py play 1
python3 rx3-control.py play 2

# verify
python3 rx3-control.py query
```

Expected output:

```
input0 route=0 xfassign=1 fader=0.000 trim=0.000 cfxtype=0 cfxcolor=0.000
input1 route=1 xfassign=2 fader=0.000 trim=0.000 cfxtype=0 cfxcolor=0.000
player0 playing=1 tempo=0.000
player1 playing=1 tempo=0.000
realmixer=0
```

`playing=1` on both lines = success. (`tempo=0.000` is the hardware
limit — no audio clock.)

### Case-insensitivity patch (optional)

If you don't want to remember lowercase:

```bash
sed -i 's/def key_of(name): return keys\[name\] if name in keys else int(name,0)/def key_of(name):\n    n=name.lower()\n    return keys[n] if n in keys else int(name,0)/' ~/Rx3-flx4/rx3-handoff/rx3-control.py
```

Then `CUE`, `Cue`, and `cue` all work.

### Shell shortcuts

Add to `~/.profile`:

```bash
rx3() { cd ~/Rx3-flx4/rx3-handoff && python3 rx3-control.py "$@"; cd - >/dev/null; }
rx3-both() { rx3 play 1; rx3 play 2; }
rx3-stop() { rx3 play 1; rx3 play 2; }
```

Then: `rx3 query`, `rx3 usb1`, `rx3 cue 1`, `rx3-both`, `rx3-stop`.

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

### `ValueError: invalid literal for int() with base 0: 'CUE'`

Key names are **lowercase**. Use `cue`, `play`, `sync`, etc. Or use hex:
`0x4102`. Or apply the case-insensitivity patch above.

Full list of valid names:

```
back beatjump beatloop browse color cross cue deckselect enter eqh eql eqm
fader headphones hotcue hpcue hpmix info jog jogtouch load loopin loopout
master masterlv mastertempo menu pad1..pad8 play playlist quantize reloop
search shift slip source sync tempo temporange trackfwd trackrev trim
usb1 usb2 usbstop vinyl
```

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

If it's on the wrong device, restart the bridge:

```bash
sudo systemctl restart rx3-pointer
```

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

Do **not** waste time trying to fake the cs4344 codec with ALSA plugins
— it was tested extensively and fails at `snd_pcm_hw_params_set_channels`
because the Duet's card advertises `CHANNELS: 2` on every PCM.

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
| `~/README.md` | This file |
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

**Save it:**

```bash
nano ~/README.md    # paste, Ctrl+O, Enter, Ctrl+X
```

**Back it up:**

```bash
cp ~/README.md ~/rx3-final/
```

The key addition versus the previous README: the **complete lowercase keymap** and the `ValueError: invalid literal for int()` troubleshooting entry — the exact error you just hit. Now it's documented so you won't have to rediscover it.# XDJ-RX3 Firmware Emulation on Lenovo Duet 1

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
