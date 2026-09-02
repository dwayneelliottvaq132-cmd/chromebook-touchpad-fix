# chromebook-touchpad-fix

Makes the internal touchpad work after a fresh Linux install on a Chromebook.

Verified on: Google **Telith** (Chromebook), Pixart I2C-HID touchpad `093A:200F`,
Kali rolling 2026.3, kernel 7.0, XFCE on X11. The detection is generic, so it
should work on other Chromebooks with the same class of touchpad.

## Recovery after a reinstall

```sh
sudo apt install -y git gh          # gh only needed for a private clone
gh auth login                       # skip if you use a token or SSH key
git clone https://github.com/dwayneelliottvaq132-cmd/chromebook-touchpad-fix.git
sudo ./chromebook-touchpad-fix/chromebook-touchpad-setup.sh
```

Then **log out and back in** so Xorg picks up the driver change.

## The problem

Two independent issues, and the first is the one that actually kills the pointer:

**1. Missing libinput quirk.** The kernel enumerates the pad fine — the whole
driver stack (`hid-multitouch` → `i2c_hid_acpi` → `i2c_designware` →
`intel-lpss`) binds with zero configuration, and the device shows up in
`xinput list`. But libinput's shipped quirks database has *no entry* for this
device, so no `AttrPressureRange` applies and libinput's pressure-based touch
detection gates all motion. Physical clicks keep working because they take a
separate code path, which makes it look like a half-broken pad rather than a
missing one-line quirk.

`AttrPressureRange=0:-2` makes a touch always logically "down", so libinput
tracks fingers by MT tracking ID instead of by pressure. That is what every
upstream Chromebook Pixart entry does (Banshee `093A:0274`, Roric/Rull
`093A:3307`); this repo just adds the same for a device upstream hasn't
catalogued yet.

**2. Xorg driver claim.** `/usr/share/X11/xorg.conf.d/70-synaptics.conf` claims
every touchpad via a catchall `InputClass`, so an override has to sort *after*
`70-` to win the driver claim for libinput. That is the tuning half:
tap-to-click, clickfinger, natural scroll.

Nothing here depends on kernel parameters, `modprobe.d` entries, or initramfs
tweaks — the working system has a completely stock `/proc/cmdline`.

## Usage

```sh
sudo ./chromebook-touchpad-setup.sh              # diagnose + apply
     ./chromebook-touchpad-setup.sh --status     # report only, no changes
     ./chromebook-touchpad-setup.sh --dry-run    # show what would be written
sudo ./chromebook-touchpad-setup.sh --revert     # remove what it wrote
sudo ./chromebook-touchpad-setup.sh --no-xorg    # quirk only; use this on Wayland
sudo ./chromebook-touchpad-setup.sh --disable-mouse-sibling
```

The script detects the touchpad from `/proc/bus/input/devices` and DMI rather
than hardcoding IDs, backs up any file it replaces to `.bak`, and verifies
afterward that the quirk actually took effect — a syntax error makes libinput
silently drop the entire file, which would look exactly like the original bug.

`--disable-mouse-sibling` is off by default. The I2C-HID descriptor exposes a
duplicate plain-mouse collection alongside the multitouch one; it is normally
inert, but some desktops surface it as a second pointer whose settings fight the
real device. The flag ignores it via an Xorg rule matched on the exact product
name, so real USB and Bluetooth mice are untouched.

## What it writes

| Path | Purpose |
| --- | --- |
| `/etc/libinput/local-overrides.quirks` | The actual fix — `AttrPressureRange` |
| `/etc/X11/xorg.conf.d/99-touchpad.conf` | libinput driver claim + tuning |
| `/etc/X11/xorg.conf.d/99-touchpad-mouse-sibling.conf` | Only with `--disable-mouse-sibling` |

Known-good copies of these, captured from a working system, are in
[`reference/`](reference/) — ground truth if the script's detection ever
misfires on new hardware.

## If the touchpad doesn't appear at all

If nothing shows up in `/proc/bus/input/devices`, this is a kernel or firmware
problem and no config file will help. Run `--status`; the script prints an
ordered checklist covering ACPI `PNP0C50` presence, the module stack (including
the SoC pinctrl driver that the GPIO interrupt depends on), the kernel version
floor for the SoC, and what to grep for in `dmesg`.

## Verifying

```sh
libinput quirks list /dev/input/eventN     # should show AttrPressureRange=0:-2
sudo libinput debug-events                 # drag a finger; expect POINTER_MOTION
```
