# XDJ-RX3 Firmware Emulation on Lenovo Duet 1

Running the Pioneer XDJ-RX3 v1.19 ARM32 firmware **natively** on a Lenovo
Duet 1 (MediaTek MT8183, `google-krane`, postmarketOS / Alpine + systemd).
The aarch64 kernel's `CONFIG_COMPAT` executes 32-bit ARM directly —
**no QEMU, no emulation**.

## Tested on

| Component   | Value                                         |
|-------------|-----------------------------------------------|
| Device      | Lenovo Duet 1 (`google-krane`, MT8183)        |
| OS          | postmarketOS (Alpine, systemd)                |
| Kernel      | 6.18.28-mt81 (aarch64, CONFIG_COMPAT=y)       |
| Display     | 1200×1920 DSI, `mediatekdrmfb`                |
| Rotation    | 270° clockwise                                |
| Touchscreen | `hid-over-i2c 27C6:0E30` (bare interface)     |
| User        | `user` (uid 10000), home `/home/user`         |

## Quick install

```bash
bash ~/rx3-duet1-install.sh 2>&1 | tee ~/rx3-install.log
```

The installer pauses at firmware recovery. Have ready:
1. **XDJ-RX3 v1.19 update** (.zip) from AlphaTheta support downloads
2. **Pioneer GPL source distribution** (.zip) from Pioneer's open-source page

After install:

```bash
sudo systemctl start rx3
sleep 15
sudo systemctl start rx3-pointer
systemctl status rx3 rx3-pointer --no-pager | grep -E '●|Active:'
```

On the Duet the firmware boots in ~15 s (native ARM32, no emulation).

## Features

| Feature | Status |
|---------|--------|
| RX3 UI on panel, rotation 270 | ✅ |
| Touch input (overlay buttons) | ✅ |
| Swipe-up to reveal overlay | ✅ |
| Auto-hide overlay after 8 s | ✅ |
| Keyboard control | ✅ |
| USB hotplug | ✅ |
| Autostart on boot | ✅ |
| Audio | ❌ firmware gate — see below |

### Overlay behavior

- **Visible on boot** — the 12 buttons and 6 sliders
- **Auto-hides 8 s** after your last touch
- **Swipe up** on the screen to bring it back
- While visible, buttons fire on tap; the timer resets on every touch
- While hidden, the firmware UI runs fullscreen

The overlay and the firmware share a byte at offset 48 of
`~/rx3-rootfs/dev/rx3-ui-state`. The presenter reads it to decide
whether to draw chrome; the touch bridge writes it.

## Daily use

| Task | Command |
|------|---------|
| Status | `systemctl status rx3 rx3-pointer --no-pager` |
| Restart | `sudo systemctl restart rx3 && sleep 15 && sudo systemctl restart rx3-pointer` |
| Stop | `sudo systemctl stop rx3-pointer rx3` |
| Player log | `tail -40 /tmp/player.log` |
| Touch log | `tail -20 ~/rx3-touch.log` |
| Firmware state | `python3 ~/Rx3-flx4/rx3-handoff/rx3-control.py query` |

### Keyboard control

```bash
cd ~/Rx3-flx4/rx3-handoff
C="python3 rx3-control.py"

$C source;    sleep 1     # open SOURCE menu
$C usb1;      sleep 1     # select USB1
$C rotary +1; sleep 0.5   # scroll
$C enter;     sleep 1     # enter folder
$C load 0;    sleep 1     # load to deck 1
$C play 0;    sleep 1     # play
$C query                  # dump engine state
```

**Put ~0.5–1 second between commands.** The firmware drops rapid input.

### USB

```bash
ls /dev/sd*                  # find partition (sda1, sdb1, ...)
# plug in a FAT32/exFAT stick
sudo journalctl -t rx3 -f    # watch for "usb1 attached"
python3 ~/Rx3-flx4/rx3-handoff/rx3-control.py mount usb1 /media/usb1/sdX1
```

On the UI: **SOURCE → USB1**.

## The seven patches that make it work

All baked into the installer. Listed here so you understand what's
non-standard if you ever need to debug or re-apply.

### 1. `patch-player.py` — `getPcController` NULL fix

The upstream repo doesn't include this. Without it, the firmware segfaults
at startup with `si_addr=0x9c` (NULL deref at offset 0x9c):

```python
words(0x31df70, 0xe3a00000)   # mov r0, #0
```

### 2. `control-shim.c` — input gate re-unlock

`notify1stKeyHandled(manager, 3)` releases the firmware's startup input
gate. On the Duet, the UI re-locks it after init. The shim now has a
background `gate_thread` that re-calls it every 10 seconds, and calls it
again before every `sendkey`.

### 3. `rx3-control.py` — `op=0` for button press (Duet-specific)

**This is the opposite of other machines.** On the Duet the firmware needs:

```python
send(k,0,ch); time.sleep(.1); send(k,2,ch)
```

Using `op=1` (which is correct on the Chuwi MiniBook and other x86_64 hosts)
**resets the entire mixer state to 0.000** and corrupts the input handler.

### 4. `fb-present.c` — `-hidable` flag

Adds a `-hidable` flag: chrome (buttons + sliders) is drawn only when
`state->overlay_visible` is set. The `idx[]` panel-to-canvas map is
recomputed when the mode changes: letterboxed when chrome is drawn,
fullscreen stretch when it's hidden.

### 5. `touch-bridge.c` — swipe up + auto-hide

- Records `y_min`/`y_max`/`t_start` on finger-down
- On release: if `y_max - y_min > 250` and elapsed `< 700 ms` → sets
  `overlay_visible = 1` (span is direction-agnostic, so up works)
- Clears `overlay_visible` when `now - last_touch > 8000 ms`
- Any finger-down while overlay is visible resets the timer

### 6. `usb-attach.sh` — mknod hex→decimal

Alpine's BusyBox `mknod` and Debian's coreutils both reject the `0x`
prefix. The fix converts:

```bash
mknod $R/dev/$PART b $((16#$(stat -c %t "$SRC"))) $((16#$(stat -c %T "$SRC")))
```

### 7. `usb-hotplug.sh` — retry loop

The upstream one-shot `rx3-control.py mount` call often misses because the
FIFO isn't ready when udev fires. Now retries 15 times, 1 s apart, and logs
`(mount event sent=1)` on success.

## Audio limitation

The firmware's audio engine opens an ALSA card named `cs4344audiorev8`
(the Cirrus CS4344 DAC the real XDJ-RX3 uses). No such card exists on a
laptop or tablet. The play state toggles correctly (`player0 playing=1`)
but no audio samples reach any hardware.

The **only** fix is a physical **Pioneer DDJ-FLX4** connected via USB —
the project's `fbshim.c` redirects the firmware's ALSA calls to the
controller's USB sound card. Without it, no sound.

Fixing this without the controller would require Ghidra + ARM32
reverse-engineering of `rbp-pi`.

## Troubleshooting

### Player segfaults at startup (`si_addr=0x9c`)

The `getPcController` patch is missing. Verify:

```bash
arm-linux-gnueabi-objdump -d ~/rx3-rootfs/root/pdj/rbp-pi \
    --start-address=0x31df6c --stop-address=0x31df78
```

Expect `31df70: e3a00000  mov r0, #0`.

### `build-rootfs.sh` fails with `Permission denied` / `Resource busy`

Stale bind mounts. Reboot or unmount manually:

```bash
sudo systemctl stop rx3 rx3-pointer
sudo pkill -9 -f rbp-pi
for m in $(mount | awk '/rx3-rootfs/ {print $3}' | sort -r); do
    sudo umount -l "$m" 2>/dev/null || true
done
mount | grep rx3-rootfs   # should be empty
./build-rootfs.sh
```

### `source` opens but nothing else works

The firmware's input gate re-locked. Restart the player:

```bash
sudo systemctl restart rx3
sleep 15
```

### `op=1` corruption

If the mixer query shows `fader=0.000` after a button press, you're using
`op=1`. Fix:

```bash
cd ~/Rx3-flx4/rx3-handoff
sed -i '40s|send(k,1,ch)|send(k,0,ch)|' rx3-control.py
```

### Overlay doesn't auto-hide

Check that the touch bridge is running and idle:

```bash
pgrep -af rx3-touch-bridge
xxd -s 48 -l 4 ~/rx3-rootfs/dev/rx3-ui-state
```

`0000 0000` = hidden. `0100 0000` = visible. If it stays `0100 0000` with
no touches, a finger's down flag is stuck — restart the bridge:

```bash
sudo systemctl restart rx3-pointer
```

### Swipe doesn't reveal overlay

The gesture must be a **drag**: finger down, slide across the screen,
then lift. A tap won't trigger it. If drags don't work, check the log:

```bash
tail -20 ~/rx3-touch.log
```

Look for `touch begin` lines. If they appear but the overlay stays hidden,
the touch threshold (250 canvas pixels) is too high — lower it in
`touch-bridge.c` and rebuild.

## Backup

After a working install:

```bash
ls -la ~/rx3-final/
```

Contains: source files, compiled binaries, service unit, and `rx3.conf`.
Copy `~/rx3-final/` and `~/rx3-duet1-install.sh` to a USB stick or cloud.

## Machine comparison

| Machine | Arch | Firmware runs via | Buttons op | Notes |
|---------|------|-------------------|-----------|-------|
| **Duet 1** | ARM64 | native CONFIG_COMPAT | **0** | fast; op=1 corrupts mixer |
| Chuwi MiniBook | x86_64 | QEMU ARM32 | 1 | slow; op=0 silently ignored |
| Lenovo laptops | x86_64 | QEMU ARM32 | 1 | same as Chuwi |
| Pi 4 + 5" DSI | ARM64 | native CONFIG_COMPAT | 0 | 800×480 panel, UI text small |
| Pi 5 + 7" | ARM64 | native CONFIG_COMPAT | 0 | project's target hardware |
```

---

## Install

```bash
chmod +x ~/rx3-duet1-install.sh
~/rx3-duet1-install.sh 2>&1 | tee ~/rx3-install.log
```

Have the firmware `.zip` files ready — it pauses at step 7.

The installer:
1. Installs Alpine packages
2. Symlinks `armv7-*` toolchain → `arm-linux-gnueabi-*`
3. Symlinks kernel uapi headers into the armv7 sysroot
4. Tests 32-bit ARM execution
5. Clones the repo
6. **Patches all eight source files in one Python block** (patch-player.py, build-rootfs.sh, control-shim.c, pi-controls.h, fb-present.c, touch-bridge.c, rx3-control.py, usb-attach.sh, usb-hotplug.sh)
7. Recovers firmware (interactive)
8. Builds the chroot
9. Binds `/proc/asound`
10. Compiles `rx3-fb-present` and `rx3-touch-bridge`
11. Runs upstream `install.sh` for the systemd unit and udev rules
12. Installs `rx3-pointer.service` with auto-detect
13. Saves everything to `~/rx3-final/`

Every patch has an idempotent check — re-running is safe. If a pattern doesn't match (because the upstream file changed), the patcher reports `MISS: filename:tag` and continues, so you can see exactly what failed.

## After install

```bash
sudo systemctl start rx3
sleep 15
sudo systemctl start rx3-pointer

systemctl status rx3 rx3-pointer --no-pager | grep -E '●|Active:'
pgrep -af 'rbp-pi|rx3-fb-present|rx3-touch-bridge'
```

Three processes; UI on the panel; overlay visible; swipe up works.

**Paste the final `INSTALL COMPLETE` block and the `pgrep` output if anything fails** — every step logs clearly with `==>` headers so we can see exactly where it broke.
