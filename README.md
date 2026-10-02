# Rx3-flx4 for Lenovo Duet 1 (postmarketOS)

Run the Pioneer XDJ-RX3 firmware on a Lenovo Duet 1 (MediaTek MT8183,
`google-krane`) running postmarketOS / Alpine + systemd. Native ARM32
execution via `CONFIG_COMPAT` — no QEMU.

Based on the `Rx3-flx4.zip` bundled in
[DRCRecoveryData/rx3-pi4-7inch](https://github.com/DRCRecoveryData/rx3-pi4-7inch),
adapted for the Duet's hardware: 1200×1920 portrait panel, `mediatekdrmfb`
framebuffer, and `hid-over-i2c 27C6:0E30` touchscreen.

---

## What this installs

A working XDJ-RX3 firmware emulation:

- Firmware (v1.19) boots in an ARM32 chroot and renders its own UI on the Duet panel
- **Touchscreen** works (swipe-up overlay, on-screen buttons)
- **DDJ-FLX4** controls the firmware — transport, mixer, browse, cue
- **Master audio** out through the FLX4's RCA
- **Headphone cue** on the FLX4's headphone jack (USB channels 3/4)
- USB media hot-plug (subject to overlay completion — see Known limits)
- Starts automatically at boot via `rx3.service`

---

## Hardware required

| Item | Required |
|---|---|
| Lenovo Duet 1 (or any MT8183 / `google-krane` board) | yes |
| postmarketOS or Alpine Linux + systemd | yes |
| Pioneer **DDJ-FLX4** (the sound card *and* the control surface) | yes |
| 32-bit ARM execution enabled (`CONFIG_COMPAT`) | yes |
| XDJ-RX3 v1.19 firmware update zip | for recovery step |
| Pioneer GPL source zips | for recovery step |

The FLX4 must be connected **before** the player starts. If it isn't, the
service falls back to ALSA Loopback (silent).

---

## Files in this repo

- `rx3-duet1-pmos.sh` — the installer (this script)
- `README.md` — this document

---

## Install

```bash
git clone https://github.com/DRCRecoveryData/rx3-pi4-7inch.git
cd rx3-pi4-7inch
chmod +x rx3-duet1-pmos.sh
bash rx3-duet1-pmos.sh 2>&1 | tee ~/rx3-install.log
```

**Do not run as root.** The script calls `sudo` itself.

The install takes 5–15 minutes depending on download speed and CPU.

---

## What the script does

In order:

| # | Step |
|---|---|
| 1 | Stops and removes any previous install (services, udev, chroot, binaries) |
| 2 | Installs Alpine packages (`gcc-armv7`, `fuse-overlayfs`, `py3-pillow`, etc.) |
| 3 | Symlinks `armv7-alpine-…-gcc` → `arm-linux-gnueabi-gcc` |
| 4 | Links kernel uapi headers into the armv7 sysroot |
| 5 | Tests 32-bit ARM execution — fails fast if `CONFIG_COMPAT` is off |
| 6 | Clones this repo, extracts `Rx3-flx4.zip`, flattens to `~/Rx3-flx4/` |
| 7 | **Adds the `0x31df70` crash fix** to `patch-player.py` |
| 8 | Writes `~/Rx3-flx4/rx3-handoff/rx3.conf` (`RX3_ROTATE=270`, `RX3_FPS=30`, `RX3_FILTER=nearest`) |
| 9 | Recovers firmware (`recover-firmware.py`, `extract_cramfs.py`) |
| 10 | Runs `./install.sh doctor` |
| 11 | Builds the chroot (`./build-rootfs.sh`), **verifies `0x315f70 == 0xe3a00000`** |
| 12 | **Enlarges the dmix buffer** in `asound.conf` (`period_size 1024`, `buffer_size 8192`) — fixes cue-underrun |
| 13 | Runs the upstream `./install.sh` (builds helpers, installs service, udev, masks PipeWire) |
| 14 | Adds your user to the **`input` group** — required for the touch bridge |
| 15 | **Creates `rx3-pointer.service`** for the Duet's `hid-over-i2c 27C6:0E30` panel |
| 16 | Enables `rx3.service` |

---

## Why this differs from the upstream Pi 4 / 7″ installer

The upstream `Rx3-flx4.zip` targets a **Raspberry Pi 4 with a 7″ DSI
touchscreen** (800×480 landscape, `edt_ft5x06` touch driver, `vc4drmfb`
framebuffer). The Duet is different enough that four extra changes are
required:

### 1. The `0x31df70` crash fix

The firmware's `ui::IUiObjManager::getPcController()` dereferences a global
that is NULL when the controller-handle lookup hasn't completed, causing a
NULL-pointer segfault at `[r3+0x9c]` (`si_addr=0x9c`). The fix writes
`mov r0, #0` (`0xe3a00000`) at **file offset `0x315f70`** — which is VA
`0x31df70` minus the ELF load base `0x8000`.

The upstream `patch-player.py` doesn't include this fix; the script adds it
and verifies the resulting byte in the chroot binary.

### 2. The dmix buffer size

The zip ships `period_size 128 / buffer_size 512` — about 11 ms at 44.1 kHz.
On MT8183 this underruns easily. The symptom: **cue audio plays for a few
seconds then goes silent, while master keeps working.** The script bumps the
buffer to 1024 / 8192 (~186 ms), which fixes it.

### 3. The `input` group

`/dev/input/event*` is owned `root:input` mode `660`. The upstream
`input-hotplug.sh` runs the touch bridge as the login user (`linux`), which
isn't in `input`, so it can't open the panel — you get `open: Permission
denied` in `~/rx3-touch.log`. The script adds your user to `input`.

### 4. `rx3-pointer.service`

The new zip relies on `input-hotplug.sh` to spawn the touch bridge as a
transient systemd unit. That works, but the unit isn't persistent across
`rx3.service` restarts. This script installs a proper unit that binds to
`rx3.service` and restarts the bridge automatically.

---

## After install

The script enables `rx3.service` but does **not** start it. Start manually:

```bash
sudo systemctl start rx3
sleep 15
sudo systemctl start rx3-pointer
```

Check:

```bash
systemctl status rx3 rx3-pointer --no-pager | grep -E 'Active|●'
pgrep -af 'rbp-pi|rx3-fb-present|rx3-touch-bridge'
```

You should see three processes: `rbp-pi` (the firmware), `rx3-fb-present`
(the framebuffer presenter), and `rx3-touch-bridge`.

### First boot after install

If you added yourself to the `input` group in step 14, **log out and back
in** (or reboot) so the new group takes effect for your session. Otherwise
the touch bridge will fail with `Permission denied` until you do.

---

## Settings — `rx3.conf`

The installer writes these to `~/Rx3-flx4/rx3-handoff/rx3.conf`:

| Variable | Value | Why |
|---|---|---|
| `RX3_ROTATE` | `270` | Duet's panel is portrait 1200×1920; the firmware's 1280×800 canvas is rotated into it |
| `RX3_FPS` | `30` | Halves the presenter's work vs 60 fps — smoother waveform on MT8183 |
| `RX3_FILTER` | `nearest` | ~⅓ the CPU of bilinear; a small quality trade-off |

To change any of them:

```bash
nano ~/Rx3-flx4/rx3-handoff/rx3.conf
sudo systemctl restart rx3
```

If the waveform is still laggy, try `RX3_FPS=24`. If it's smooth and you
want prettier text, remove `RX3_FILTER` (falls back to bilinear).

---

## Logs

| File | Contents |
|---|---|
| `journalctl -u rx3 -f` | Service and start-script output |
| `~/rx3-player.log` | Firmware stdout / stderr (DirectFB init, control adapter, PCM opens) |
| `~/rx3-controller.log` | Every MIDI message the FLX4 sends and the firmware key it maps to |
| `~/rx3-touch.log` | Touch bridge: device, geometry, each touch event |
| `~/rx3-present.log` | Presenter: frames/s and rendered/s, logged once a minute |
| `journalctl -t rx3` | USB attach events, hotplug, controller detection |

---

## Troubleshooting

### The player crashes on start (`Segmentation fault`)

Check the crash fix landed:

```bash
python3 -c "b=open('/home/linux/rx3-rootfs/root/pdj/rbp-pi','rb').read(); print(hex(int.from_bytes(b[0x315f70:0x315f74],'little')))"
```

Must print `0xe3a00000`. If not, the script's step 7 or 11 failed — re-run
`./install.sh` from `~/Rx3-flx4/rx3-handoff`.

### No sound from the headphone cue

Three things must all be true:

1. The FLX4's **HEADPHONES MIX** knob is turned toward **CUE** (left). If
   it's fully right, you only hear master.
2. The **CUE** button on FLX4 channel 1 is pressed (LED lit). Without it,
   the firmware doesn't write cue audio.
3. The dmix buffer is large enough. Verify:

   ```bash
   grep -E 'period_size|buffer_size' ~/rx3-rootfs/etc/asound.conf
   ```

   Should be `1024` / `8192`. If it's `128` / `512`, re-run the installer's
   step 12 or edit it manually and restart `rx3`.

Check the shim's peak meter while a track plays:

```bash
watch -n 1 cat /tmp/rx3-audio-peaks
```

`rx3out` shows master peaks; `rx3cue` shows cue peaks. If `rx3cue` stays at
0 while master is loud, the firmware isn't producing cue audio — verify
the FLX4's CUE button is pressed.

### Touch doesn't work

```bash
pgrep -af rx3-touch-bridge
cat ~/rx3-touch.log
```

- **Bridge not running** → `sudo systemctl start rx3-pointer`
- **`open: Permission denied`** → you're not in the `input` group yet. Log
  out and back in (or reboot), then restart the service.
- **Bridge running but UI doesn't respond to taps** → the touch bridge is
  writing to the chroot FIFO but the firmware isn't reading it. Check the
  player is running: `pgrep -af rbp-pi`.

### The FLX4 doesn't control the firmware

```bash
systemctl status rx3-bridge --no-pager
tail -20 ~/rx3-controller.log
```

You should see lines like:

```
midi 90 0c 7f
key=4102 op=0 ch=1
```

…for every button press. If MIDI is arriving but no `key=` lines follow,
the bridge mapping for that control is missing. If no MIDI arrives at all,
the FLX4 isn't sending — check `sudo amidi -p hw:2,0,0 -d`.

### Waveform is laggy or glitchy

The presenter is compositing 1280×800 → 1200×1920 in software. On MT8183
this is the ceiling. Try:

```bash
echo 'RX3_FPS=24' >> ~/Rx3-flx4/rx3-handoff/rx3.conf
sudo systemctl restart rx3
```

If it's still bad, check that both FPS and filter tuning are active:

```bash
cat ~/Rx3-flx4/rx3-handoff/rx3.conf
ps -eo pid,pcpu,comm | grep rx3-fb-present
```

If `rx3-fb-present` is pegged at 100% of a core, the renderer is the limit.
If it's below 50% but the waveform still stutters, the audio side is the
issue — increase the dmix buffer further (`period_size 2048`,
`buffer_size 16384`).

### FLX4 not detected at boot

The FLX4 must be connected before `rx3.service` starts. If it enumerates
late, restart:

```bash
sudo systemctl restart rx3
```

The journal will show `audio card: DDJFLX4` if detection succeeded, or
`audio card: Loopback` if it fell back.

---

## Known limits

- **USB media in SOURCE** may not appear if the overlay layer isn't composed
  (`mount | grep rx3-usb` should show an `overlay` mount, not just `lower`).
  This is a script-side issue in the current upstream `usb-attach.sh` and
  isn't fixed here.
- **Pad mode LEDs** on the FLX4 (hot cue, beat jump) stay dark; the pads
  work but don't reflect firmware state.
- **Microphone, AUX, recording** are untested.
- **CPU load** — the MT8183 is roughly 5× slower than a Pi 5 for this
  workload. Expect 30 fps UI, occasional frame drops during heavy library
  scrolling, and the CPU fan (if any) to run.

---

## Uninstall

```bash
sudo systemctl disable --now rx3 rx3-pointer
sudo rm -f /etc/systemd/system/rx3*.service
sudo rm -f /etc/udev/rules.d/*rx3*
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
for m in $(findmnt -rn -o TARGET | grep -E "^$HOME/rx3-rootfs/"); do sudo umount -l "$m"; done
rm -rf ~/rx3-rootfs ~/rx3-usb ~/Rx3-flx4 ~/rx3-fb-present ~/rx3-touch-bridge
rm -f ~/rx3-*.log
```

Or run the installer again — its step 1 does a full clean before installing.

---

## Credits

- [mutlisensor/Rx3-flx4](https://github.com/mutlisensor/Rx3-flx4) — original Pi 5 port
- [DRCRecoveryData/rx3-pi4-7inch](https://github.com/DRCRecoveryData/rx3-pi4-7inch) — Pi 4 + 7″ fork with the newer zip
- This script — Lenovo Duet 1 / MT8183 / postmarketOS adaptation

---

## License

Same as the upstream `Rx3-flx4` project. The XDJ-RX3 firmware is property of
AlphaTheta / Pioneer DJ and is not distributed here — you supply it.
