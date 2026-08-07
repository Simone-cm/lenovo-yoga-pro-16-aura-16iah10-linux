# Lenovo Yoga Pro 16 Aura Edition (16IAH10) — Ubuntu Linux notes

Model: Lenovo Yoga Pro 16 Aura Edition, 16IAH10 (DMI product `83L0`)
GPU: Intel Arrow Lake-P (Arc Pro 130T/140T, integrated) + NVIDIA GeForce RTX 5060 Max-Q (discrete, hybrid graphics)
OS: Ubuntu 26.04 LTS, kernel `7.0.0-29-generic`

This repo collects what works/doesn't work and the fixes applied to run Ubuntu well on this laptop.

## Component status

| Component | Status | Notes |
|---|---|---|
| Internal display (panel) | ✅ Working | — |
| VRR (panel, Variable Refresh Rate) | ✅ Working | ⚠️ Known GNOME/Mutter bug loses VRR sync on resume from sleep — workaround in fix #5 |
| Touchpad (Synaptics `SYNA2BA6:00`) | ✅ Working | ⚠️ Middle-click needs the `gsettings` fix in #3, otherwise misbehaves |
| Keyboard | ✅ Working | — |
| Trackpad scroll speed (Wayland) | ✅ Working | Needs the **Wayland Scroll Factor** app, see fix #4 — no native GNOME control |
| Webcam (Bison Electronics, RGB) | ✅ Working | `/dev/video0`/`video1` |
| IR camera (Windows Hello-style) | 🟡 Working, needs manual setup | No pre-built Howdy package for Ubuntu 26.04 (`resolute`) yet — built from source, see `howdy` section below. `/dev/video2`/`video3` |
| Intel Arrow Lake-P iGPU | ✅ Working | Runs on `xe` driver (fix #1) — not required, but smoother and `i915` is being phased out |
| NVIDIA RTX 5060 Max-Q (dGPU) | ✅ Working | ⚠️ Use driver **610-open or newer** for correct gaming performance, see fix #1b |
| Hybrid graphics switching | ✅ Working | — |
| GPU performance (overall) | 🟡 Conditional | ⚠️ Requires the `performance` power profile — `balanced`/`power-saver` caps GPU usage, see fix #2 |
| Suspend/resume (s2idle) | ✅ Working | NVIDIA suspend/resume/hibernate systemd units present and hooked in; not yet stress-tested — see TODO |
| Occasional GPU hangs/freezes | 🟡 Rare, unresolved upstream | Tracked as [i915 kernel#14469](https://gitlab.freedesktop.org/drm/i915/kernel/-/issues/14469) — see fix #6. Uncertain whether it fully applies to Arrow Lake vs. the Meteor Lake hardware in that thread |
| Firefox (Snap build) | ❌ Broken | No Intel Arc hardware acceleration — replace with `.deb` build, see fix #7 |
| Wi-Fi / Bluetooth | ✅ Working | — |
| Battery / power management | ✅ Working | — |

## Fixes applied

### 1. Intel graphics driver: `i915` disabled in favor of `xe`

Not strictly required — Arrow Lake-P works with either driver — but `xe` gives a noticeably smoother experience (better power management, fewer glitches) and `i915` is the legacy driver being phased out across the board for newer Intel GPUs. Switching now avoids depending on a driver that's being deprecated.

Configured via kernel cmdline in `/etc/default/grub`:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash i915.force_probe=!7d51 xe.force_probe=7d51"
```

This tells `i915` **not** to probe PCI ID `7d51` (Arrow Lake-P) and forces `xe` to probe it instead. After editing: `sudo update-grub` and reboot.

Verify it's active:
```
lsmod | grep -E '^xe |^i915'
cat /proc/cmdline
```

### 1b. NVIDIA driver: use at least version 610 (open kernel modules)

Strongly recommended: install NVIDIA driver **610-open or newer** (`nvidia-driver-610-open`). Older driver versions have noticeably worse gaming performance on this GPU (RTX 5060 Max-Q, Blackwell architecture) — the open-kernel-module variant is now the recommended/default one for this GPU generation, not the legacy proprietary modules.

Check current version:
```
nvidia-smi --query-gpu=driver_version,name --format=csv
```
Install/upgrade:
```
sudo apt install nvidia-driver-610-open
```

### 2. Performance mode required to use the full GPU

**If the power profile isn't set to `performance`, the GPU (especially the discrete NVIDIA one) isn't fully utilized.** With `balanced` or `power-saver` performance is clearly capped.

Check/set:
```
powerprofilesctl list
powerprofilesctl set performance
```

The chosen profile is also persisted at the GNOME session level (`last-selected-power-profile` in dconf) — already set to `performance` on this machine.

### 3. Touchpad middle-click fix

The actual working fix is a single `gsettings` command:
```
gsettings set org.gnome.desktop.peripherals.touchpad middle-click-emulation true
```
Setting `middle-click-emulation` to `true` fixes the unwanted middle-click behavior on this Synaptics touchpad (`SYNA2BA6:00 06CB:CFD3 Mouse`) — counterintuitive (the name suggests it *enables* emulation rather than fixing something), but it's the confirmed working command. Persists via dconf/gsettings, no extra package or service required.

Verify:
```
gsettings get org.gnome.desktop.peripherals.touchpad middle-click-emulation
```

(`input-remapper` was tried earlier as an alternative fix and has since been fully removed from the system — package purged, leftover config and broken systemd symlink cleaned up.)

### 4. Wayland Scroll Factor

Used to fix scroll speed/factor on Wayland (where GNOME doesn't expose a native slider for this): the **Wayland Scroll Factor** app (`io.github.danielgrasso.WaylandScrollFactor`), present among installed/favorite apps. Not managed via standard gsettings — it's a separate app acting as a translation layer for scroll events.

### 5. VRR toggle around sleep/resume (GNOME/Mutter bug workaround)

Known bug: after resuming from sleep, Mutter sometimes picks the wrong backlight/display or fails to correctly re-negotiate VRR with the panel (similar to [mutter#4111](https://gitlab.gnome.org/GNOME/mutter/-/work_items/4111) and [mutter#3419](https://gitlab.gnome.org/GNOME/mutter/-/issues/3419)). The workaround is to force a full modeset (flip VRR ON→OFF or OFF→ON and restore) right after resume.

Files in this repo:
- `scripts/toggle-vrr.sh` — CLI: `toggle-vrr.sh on|off|kick`. Uses only `gdbus` + `perl` (no extra dependencies) to talk to `org.gnome.Mutter.DisplayConfig` over D-Bus. `kick` reads the current state, flips it, then restores it — forcing the modeset. It rebuilds the full monitor configuration from Mutter's current state every time, so any other connected monitor (e.g. an external display while docked) is preserved unchanged on its current mode — only the built-in panel's (`eDP-*`) mode gets the `+vrr` suffix added/removed. Safe to run docked or undocked.
- `scripts/vrr-sleep-hook.sh` — `systemd-sleep` hook, to be installed as `/lib/systemd/system-sleep/vrr-hook.sh` (root:root, 0755). On resume (`post`), waits 2s and calls `toggle-vrr.sh kick` as user `simone`.

Install:
```
sudo cp scripts/vrr-sleep-hook.sh /lib/systemd/system-sleep/vrr-hook.sh
sudo chown root:root /lib/systemd/system-sleep/vrr-hook.sh
sudo chmod 0755 /lib/systemd/system-sleep/vrr-hook.sh
```

Test without actually suspending:
```
sudo /lib/systemd/system-sleep/vrr-hook.sh post suspend
```

### 6. Occasional freezes / GPU hangs — tracked upstream, likely PCODE/CSME firmware

Rare full-screen freezes happen occasionally (system stays alive — SSH still works, audio keeps playing — only the display output stops updating). Noticeably rarer here than on Windows on the same hardware, where similar reports describe it as much more frequent/critical.

Tracked upstream as [drm/i915 kernel issue #14469](https://gitlab.freedesktop.org/drm/i915/kernel/-/issues/14469), *"GPU Hang Intel Core Ultra 9 185H / Intel Arc Graphics (MTL)"* — open since June 2025, 48+ participants, still unresolved as of the latest comments (mid-2026). Typical `dmesg` signature right before the freeze:
```
i915 0000:00:02.0: [drm] *ERROR* GT0: GUC: TLB invalidation response timed out for seqno ...
i915 0000:00:02.0: [drm] GPU HANG: ecode 12:0:00000000
i915 0000:00:02.0: [drm] GT0: Resetting chip for stopped heartbeat on rcs0
```
(on the `xe` driver the equivalent line is `TLB invalidation fence timeout, seqno=... recv=...`).

**Note on applicability to this laptop**: the thread is specifically about the Meteor Lake (MTL) integrated GPU (PCI ID `8086:7d55`/`7d45`), reported on many different OEM laptops (Lenovo, Framework, ASUS, HP, Dell, ThinkPad, etc.) all sharing the same Intel Core Ultra 100-series/MTL silicon. This machine's GPU is Arrow Lake-P (PCI ID `7d51`, see fix #1) — a newer, different generation — and already runs on the `xe` driver by default rather than `i915`. It is not confirmed that this exact upstream bug applies to Arrow Lake; it's recorded here because the symptom (rare full freeze, system otherwise alive) matches and the underlying GuC/TLB-invalidation mechanism is shared across the two platforms.

Summary of the upstream investigation so far:
- Intel engineering (`@dceraolo`, GuC firmware team) traced it to the GuC (GPU microcontroller) losing communication with the driver during RC6 power-state wake-up, essentially a race condition — first suspected to need a **PCODE fix** (PCODE is bundled inside the platform's CSME/Intel ME firmware and shipped via BIOS updates).
- Multiple users confirm Intel's GuC team **saw the same symptom on Windows too, and it was fixed there by a PCODE update** — the working theory is the same PCODE fix should help on Linux once OEMs actually ship it.
- Results updating BIOS/CSME on Linux are **mixed and inconsistent**: several users on Lenovo (ThinkPad P1 Gen 7, Yoga 7 14IML9) and others report the hangs stopped for months after updating Intel ME/CSME to `18.1.18.2644` or newer (Lenovo package `NWME22WW`, or whatever the OEM ships it as, sometimes only downloadable/flashable from Windows). Other users updated to the same or newer CSME version and **still hit the hang**, so it is not a guaranteed fix.
- Workarounds tried and their outcome:
  - Disabling RC6 (`Render Standby` off in BIOS if available, or `i915.enable_rc6=0` via a currently-out-of-tree kernel patch) — stops the hangs for some, but increases power draw/heat and the module parameter isn't in mainline (was removed years ago; devs are hesitant to re-add it).
  - `i915.enable_dc=0` (disable display C-states) — did not help, since the bug is in the GT/render power states, not display.
  - `i915.enable_guc=0`/`=2` — GuC is mandatory on Meteor Lake, disabling it just prevents boot.
  - Switching to `xe` — inconsistent; some report fewer hangs, others report the exact same TLB-invalidation timeout on `xe` too (confirming it's a hardware/firmware issue, not i915-specific), and at least one user found `xe` *less* stable (silent hard lockups, failed resumes) than `i915` on their hardware.
  - Lower power/thermal profiles (Balanced/Power-saver instead of Performance) reduce frequency for some users — which is a direct trade-off against fix #2 in this README (performance mode needed for full GPU use).
- As of the most recent activity, the original reporter says the freezes stopped happening on their machine for the last ~6 months with unchanged firmware, suggesting whatever fixes this may partly be on the driver/kernel side rather than firmware alone — but this isn't confirmed as a general resolution, and the issue is still open upstream.

**Practical takeaway for this laptop**: no guaranteed fix exists yet. If freezes start happening more than "rare":
1. Check installed BIOS/ME firmware and update via Lenovo's site if a newer Intel ME/CSME package is available (check current version with `cat /sys/class/mei/mei0/fw_ver`).
2. Watch [issue #14469](https://gitlab.freedesktop.org/drm/i915/kernel/-/issues/14469) for updates.

### 7. Firefox from Snap breaks Intel Arc hardware acceleration

The Snap build of Firefox (Ubuntu's default) has a known bug where it fails to use Intel Arc's graphics acceleration (VA-API/hardware video decode, WebGL rendering offload), unlike the `.deb` build.

Root cause tracked upstream: [Mozilla Bugzilla #1994248 — "Firefox snap doesn't support hardware acceleration for modern GPUs"](https://bugzilla.mozilla.org/show_bug.cgi?id=1994248) (open, unconfirmed as of the last check). The report is filed against an AMD Radeon RX 9070, but the root cause is the same for Intel Arc: the Snap is built on Ubuntu's `core22` base, which bundles a Mesa version too old to have driver support for newer GPU silicon (Mesa 25.0.7+ is needed; `core22` predates it). Firefox falls back to CPU-only decoding when it can't initialize hardware acceleration, driving CPU usage to ~100% during video playback. A related earlier bug on the same root cause, already fixed once for older Intel iGPUs: [Bugzilla #1760941 — "Update Snap to core22 to have an intel-media-driver version that supports Iris Xe"](https://bugzilla.mozilla.org/show_bug.cgi?id=1760941) — confirming this has repeatedly been an issue of the Snap's bundled Mesa/media-driver lagging behind new Intel GPU generations, Arc included.

Fix: remove the Snap package and reinstall Firefox from the official `.deb` (Mozilla PPA or Mozilla's `.deb` archive):
```
sudo snap remove firefox
sudo add-apt-repository ppa:mozillateam/ppa
sudo apt update
sudo apt install firefox
```
(Ubuntu ships a pin that keeps preferring the Snap even after adding the PPA — you may need an `/etc/apt/preferences.d/mozilla-firefox` pin forcing the PPA/`.deb` package to be picked over the Snap; check `apt policy firefox` after installing to confirm the `.deb` version wins.)

### 8. Howdy (IR face login) — no Ubuntu 26.04 package, built from source

This laptop's IR camera (`Bison Electronics`, `/dev/video2`/`video3`) supports Windows-Hello-style face login via [Howdy](https://github.com/boltgolt/howdy), but there is no pre-built `.deb` for Ubuntu 26.04 (`resolute`) yet — the `ppa:boltgolt/howdy` PPA only publishes up to `questing` (25.10) as of this writing.

Following the community install guide from [howdy issue #1135](https://github.com/boltgolt/howdy/issues/1135) (originally written for Fedora 44, same underlying problem: no packages for the newest OS release), adapted for Debian/Ubuntu: build from source with Meson, install `dlib` via pip, download the face-recognition models manually, then wire Howdy into PAM for `sudo`/`polkit`/`gdm`. See build/setup notes and status as this is completed.

## TODO / to investigate

- Document any suspend/hibernate fixes needed for NVIDIA (there are `nvidia-suspend.service` / `nvidia-resume.service` / `nvidia-hibernate.service` units already hooked into systemd — verify whether they're sufficient or need overrides).
- Confirm whether updating the ME firmware via `fwupdmgr` actually reduces freeze frequency on this unit, and record the ME firmware version before/after.
