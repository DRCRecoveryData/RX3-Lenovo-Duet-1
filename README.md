
---

## Key differences from previous versions

**In the installer:**

1. **No placeholder sed patterns.** Every path the installer writes has the actual touch device baked in.
2. **`/proc/asound` bind added** to both the installer and the generated `rx3-up.sh` / `rx3-service.sh`. Without it, the firmware can't enumerate cards.
3. **`asound.conf` uses `hw:0,0` at 48000 Hz**, not `plughw` (dmix rejects plughw) and not 44100 (card is 48000-only).
4. **Log files pre-created `chmod 666`** so both root (service) and user (`rx3-up.sh`) can write them. This was the source of the "Permission denied" errors.
5. **Explicit `[ ! -f /etc/rx3-ctl ]` guard** so the file isn't recreated on every restart during debugging.
6. **USB udev rule created with `--action=add`** trigger.
7. **Touch udev symlink attempted** (best effort), with a warning if it doesn't take.

**In the README:**

1. **"What we know about the two failures"** section — the honest technical writeup of what's blocked and why, with the exact evidence (strings found, strace output, lsof output).
2. **Critical rules** now includes the `sudo -E`, `--action=add`, `pgrep -x`, dmix+plughw, and log-permission gotchas.
3. **Alpine-vs-Debian table** has rows for all the new findings.
4. **Verification checklist** has a "Failures expected" subsection for the two firmware-internal issues.
5. **All the sed placeholders are gone** — every command uses a real value.

Save both files as `~/rx3-duet1-install.sh` and `~/README-DUET1.md`. The installer is idempotent, so re-running it on your current system is safe — it'll skip the chroot build, re-detect touch, recreate the service files with the log-permission fix, and set up udev rules cleanly.
