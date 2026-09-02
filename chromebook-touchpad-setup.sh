#!/usr/bin/env bash
#
# chromebook-touchpad-setup.sh — make the internal touchpad work after a fresh
# Linux install on a Chromebook, then tune it.
#
# WHY THIS EXISTS
# ---------------
# On Google Chromebooks the internal touchpad is an I2C-HID device. The kernel
# enumerates it fine (you'll see it in `xinput list`), but libinput ships a
# quirks database that has no entry for most Chromebook Pixart/Elan touchpads.
# With no AttrPressureRange, libinput gates finger tracking on a pressure
# threshold the panel never reports the way libinput expects — so the pointer
# never moves, while physical clicks still register. It looks like a dead
# touchpad; it is actually a missing one-line quirk.
#
# The second half of the problem is Xorg: /usr/share/X11/xorg.conf.d/
# 70-synaptics.conf claims every touchpad via a catchall InputClass, so an
# override must sort AFTER 70- to win the Driver claim for libinput.
#
# This script fixes both, detecting the device rather than hardcoding it.
#
# USAGE
#   sudo ./chromebook-touchpad-setup.sh              # diagnose + apply
#        ./chromebook-touchpad-setup.sh --status     # report only, no changes
#        ./chromebook-touchpad-setup.sh --dry-run    # show what would be written
#   sudo ./chromebook-touchpad-setup.sh --revert     # remove everything it wrote
#
#   sudo ./chromebook-touchpad-setup.sh --no-xorg    # quirk only, skip Xorg tuning
#                                                    # (use this on Wayland)
#   sudo ./chromebook-touchpad-setup.sh --disable-mouse-sibling
#                                                    # hide the duplicate
#                                                    # "... Mouse" pointer node
#
# Log out and back in after applying. Tested on Kali rolling / XFCE / X11,
# kernel 7.0, Google "Telith" (Pixart 093A:200F), but the detection is generic.

set -euo pipefail

QUIRKS=/etc/libinput/local-overrides.quirks
XORGCONF=/etc/X11/xorg.conf.d/99-touchpad.conf
XORGMOUSE=/etc/X11/xorg.conf.d/99-touchpad-mouse-sibling.conf

# --- tunables -----------------------------------------------------------
NATURAL_SCROLL=true     # content follows fingers, like Chrome OS
ACCEL_SPEED=0.3         # libinput pointer speed, -1.0 .. 1.0
CLICK_METHOD=clickfinger # 1/2/3 fingers = left/right/middle on a buttonless pad
# ------------------------------------------------------------------------

MODE=apply
DO_XORG=1
DO_MOUSE_SIBLING=0
DRYRUN=0

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --status|--diagnose)     MODE=status ;;
        --revert)                MODE=revert ;;
        --dry-run|-n)            DRYRUN=1 ;;
        --no-xorg)               DO_XORG=0 ;;
        --disable-mouse-sibling) DO_MOUSE_SIBLING=1 ;;
        -h|--help)               sed -n '3,40p' "$0"; exit 0 ;;
        *)                       die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

need_root() {
    [[ $EUID -eq 0 ]] || die "This mode writes under /etc — re-run with sudo."
}

# write_file <path> <<<content   — honours --dry-run, backs up what it replaces
write_file() {
    local path=$1 content
    content=$(cat)
    if [[ $DRYRUN -eq 1 ]]; then
        say "would write $path:"
        sed 's/^/    | /' <<<"$content"
        return
    fi
    mkdir -p "$(dirname "$path")"
    if [[ -e $path ]] && ! cmp -s <(printf '%s\n' "$content") "$path"; then
        cp -a "$path" "$path.bak"
        info "backed up existing file to $path.bak"
    fi
    printf '%s\n' "$content" >"$path"
    chmod 0644 "$path"
    say "wrote $path"
}

# ---------------------------------------------------------------- detection

dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null || echo unknown; }

DMI_VENDOR=$(dmi sys_vendor)
DMI_PRODUCT=$(dmi product_name)

# Parse /proc/bus/input/devices for the first device that is a touchpad:
# EV bit + a name ending in "Touchpad", or PROP=5 (POINTER|BUTTONPAD).
# Sets TP_NAME, TP_EVENT, TP_VID, TP_PID, TP_BUS.
detect_touchpad() {
    local blk
    blk=$(awk -v RS='' '/Touchpad/ && /event/ {print; exit}' /proc/bus/input/devices) || true
    [[ -n ${blk:-} ]] || return 1

    TP_NAME=$(sed -n 's/^N: Name="\(.*\)"$/\1/p' <<<"$blk")
    TP_EVENT=$(grep -o 'event[0-9]\+' <<<"$blk" | head -1)
    TP_BUS=$(sed -n 's/^I: Bus=\([0-9a-f]*\).*/\1/p' <<<"$blk")
    TP_VID=$(sed -n 's/.*Vendor=\([0-9a-f]*\).*/\1/p' <<<"$blk" | head -1)
    TP_PID=$(sed -n 's/.*Product=\([0-9a-f]*\).*/\1/p' <<<"$blk" | head -1)
    [[ -n $TP_NAME && -n $TP_EVENT ]]
}

# When no touchpad shows up at all the problem is below libinput — kernel
# module or firmware — and no config file will help. Say so plainly.
diagnose_missing() {
    warn "No touchpad found in /proc/bus/input/devices."
    echo
    info "This is a kernel/enumeration problem, not a libinput one."
    info "Checks worth running, in order:"
    echo
    info "1. Is the I2C-HID ACPI device present in firmware?"
    info "     ls -d /sys/bus/acpi/devices/PNP0C50:* /sys/bus/acpi/devices/GOOG*"
    info "   Nothing there means the firmware isn't exposing the pad. On a"
    info "   Chromebook that usually means stock coreboot with the legacy-boot"
    info "   payload; flashing MrChromebox's full UEFI firmware is the fix."
    echo
    info "2. Are the drivers loaded?"
    info "     sudo modprobe i2c_hid_acpi hid_multitouch intel_lpss_pci"
    info "     lsmod | grep -E 'i2c_hid|hid_multitouch|intel_lpss|pinctrl'"
    info "   The GPIO interrupt needs the SoC pinctrl driver too"
    info "   (pinctrl_alderlake, pinctrl_tigerlake, pinctrl_jasperlake, ...)."
    echo
    info "3. Kernel too old for the SoC? Check 'uname -r' against the"
    info "   Chromebook's platform; ADL-N and newer want 6.1+."
    echo
    info "4. dmesg for the bus:"
    info "     sudo dmesg | grep -Ei 'i2c|hid|pinctrl|PNP0C50'"
}

# ---------------------------------------------------------------- reporting

report_status() {
    say "System"
    info "vendor/model : $DMI_VENDOR / $DMI_PRODUCT"
    info "kernel       : $(uname -r)"
    info "session      : ${XDG_SESSION_TYPE:-unknown} (${XDG_CURRENT_DESKTOP:-unknown})"

    echo
    say "Touchpad"
    if detect_touchpad; then
        info "name    : $TP_NAME"
        info "node    : /dev/input/$TP_EVENT"
        info "bus/ids : bus=$TP_BUS vendor=$TP_VID product=$TP_PID"
        # Walk up the sysfs parents printing every bound driver: this is the
        # whole stack the pad depends on (hid-multitouch -> i2c_hid_acpi ->
        # i2c_designware -> intel-lpss). A gap here is the real fault.
        local p
        p=$(readlink -f "/sys/class/input/$TP_EVENT/device" 2>/dev/null || true)
        while [[ -n $p && $p != / && $p != /sys ]]; do
            [[ -L $p/driver ]] && info "driver  : $(basename "$(readlink -f "$p/driver")")"
            p=$(dirname "$p")
        done
    else
        diagnose_missing
        return
    fi

    echo
    say "libinput quirks currently applied"
    if command -v libinput >/dev/null; then
        local q
        q=$(libinput quirks list "/dev/input/$TP_EVENT" 2>/dev/null || true)
        if [[ -n $q ]]; then
            sed 's/^/    /' <<<"$q"
            grep -q AttrPressureRange <<<"$q" \
                || warn "No AttrPressureRange — this is the usual cause of a dead pointer."
        else
            warn "No quirks apply to this device. Pointer motion is likely broken."
        fi
    else
        warn "libinput-tools not installed; cannot check quirks."
    fi

    echo
    say "Config files this script manages"
    for f in "$QUIRKS" "$XORGCONF" "$XORGMOUSE"; do
        [[ -e $f ]] && info "present : $f" || info "absent  : $f"
    done
}

# ---------------------------------------------------------------- actions

ensure_packages() {
    local want=(libinput-tools) missing=()
    if [[ $DO_XORG -eq 1 ]]; then want+=(xserver-xorg-input-libinput); fi
    command -v dpkg-query >/dev/null || return 0
    command -v apt-get    >/dev/null || return 0
    for p in "${want[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || missing+=("$p")
    done
    [[ ${#missing[@]} -eq 0 ]] && { info "packages already present: ${want[*]}"; return 0; }
    say "installing: ${missing[*]}"
    if [[ $DRYRUN -eq 1 ]]; then
        info "(dry run — skipped)"
    elif ! apt-get install -y "${missing[@]}"; then
        warn "apt install failed (no network?). Install manually: ${missing[*]}"
    fi
}

# The fix. AttrPressureRange=0:-2 makes a touch always logically "down", so
# libinput tracks fingers by MT tracking ID instead of by pressure. That is
# what every upstream Chromebook Pixart entry does; we mirror it for a device
# upstream hasn't catalogued yet.
write_quirks() {
    local section="Google Chromebook ${DMI_PRODUCT:-Touchpad}"
    write_file "$QUIRKS" <<EOF
# Local libinput quirks — $DMI_VENDOR $DMI_PRODUCT
# Generated by chromebook-touchpad-setup.sh on $(date -I)
#
# The internal touchpad ($TP_VID:$TP_PID) has no entry in libinput's shipped
# quirks database, so no quirk applies to it at all. Comparable Chromebook
# Pixart touchpads upstream (Banshee 093A:0274, Roric/Rull 093A:3307) all
# require an explicit AttrPressureRange; without one, pressure-based touch
# detection gates motion and the pointer never moves, while physical button
# clicks — which take a separate code path — still work.
#
# AttrPressureRange=0:-2 makes a touch always logically down, so libinput
# tracks fingers by MT tracking ID instead of pressure.
#
# Revert: sudo rm $QUIRKS   (then log out and back in)

[$section]
MatchUdevType=touchpad
MatchName=$TP_NAME
MatchDMIModalias=dmi:*svn${DMI_VENDOR}:*pn${DMI_PRODUCT}*
ModelChromebook=1
AttrPressureRange=0:-2
AttrThumbPressureThreshold=45
AttrPalmPressureThreshold=0
EOF
}

write_xorg() {
    write_file "$XORGCONF" <<EOF
# Written by chromebook-touchpad-setup.sh
# Must sort after 70-synaptics.conf so this InputClass wins the Driver claim.
Section "InputClass"
    Identifier          "touchpad override"
    MatchIsTouchpad     "on"
    MatchDevicePath     "/dev/input/event*"
    Driver              "libinput"

    # Tap to click, and tap-drag without needing a physical press.
    Option "Tapping"            "on"
    Option "TappingDrag"        "on"
    Option "TappingDragLock"    "off"
    # 1 finger = left, 2 = right, 3 = middle.
    Option "TappingButtonMap"   "lrm"

    Option "ScrollMethod"       "twofinger"
    Option "NaturalScrolling"   "$NATURAL_SCROLL"
    Option "HorizontalScrolling" "on"

    # clickfinger suits a buttonless Chromebook clickpad far better than
    # carving the surface into software button zones.
    Option "ClickMethod"        "$CLICK_METHOD"
    Option "MiddleEmulation"    "on"

    Option "DisableWhileTyping" "on"
    Option "AccelProfile"       "adaptive"
    Option "AccelSpeed"         "$ACCEL_SPEED"
EndSection
EOF
}

# The I2C-HID descriptor exposes a second, plain-mouse collection alongside the
# multitouch one. It is normally inert, but some desktops surface it as a
# duplicate pointer whose settings fight the real device.
write_mouse_sibling() {
    local sibling=${TP_NAME/Touchpad/Mouse}
    write_file "$XORGMOUSE" <<EOF
# Written by chromebook-touchpad-setup.sh
# Ignore the duplicate plain-mouse HID collection that the touchpad's I2C-HID
# descriptor also exposes. Matched by exact product name so real USB/Bluetooth
# mice are untouched.
Section "InputClass"
    Identifier  "ignore touchpad mouse sibling"
    MatchProduct "$sibling"
    Option "Ignore" "on"
EndSection
EOF
}

do_apply() {
    need_root
    ensure_packages

    if ! detect_touchpad; then
        diagnose_missing
        exit 1
    fi

    say "Detected touchpad: $TP_NAME ($TP_VID:$TP_PID) on /dev/input/$TP_EVENT"
    write_quirks
    if [[ $DO_XORG -eq 1 ]]; then write_xorg; fi
    if [[ $DO_MOUSE_SIBLING -eq 1 ]]; then write_mouse_sibling; fi

    if [[ $DRYRUN -eq 1 ]]; then
        say "Dry run — nothing changed."
        exit 0
    fi

    # Reject a malformed quirks file loudly: libinput ignores the whole file on
    # a parse error, which would look exactly like the bug we're fixing.
    if command -v libinput >/dev/null; then
        echo
        say "Verifying quirks now apply"
        local q
        q=$(libinput quirks list "/dev/input/$TP_EVENT" 2>&1 || true)
        sed 's/^/    /' <<<"$q"
        if grep -q 'AttrPressureRange' <<<"$q"; then
            say "AttrPressureRange is active."
        else
            warn "Quirk did NOT take effect — check $QUIRKS for a syntax error:"
            warn "  libinput quirks validate --verbose"
        fi
    fi

    echo
    say "Done. Log out and back in (or reboot) for Xorg to pick up the driver change."
    info "Verify motion with:  sudo libinput debug-events --show-keycodes"
    info "Then drag a finger — you should see POINTER_MOTION lines."
}

do_revert() {
    need_root
    for f in "$QUIRKS" "$XORGCONF" "$XORGMOUSE"; do
        if [[ -e $f ]]; then
            if [[ $DRYRUN -eq 1 ]]; then
                say "would remove $f"
            else
                rm -f "$f"
                say "removed $f"
            fi
        fi
    done
    say "Reverted to stock. Log out and back in."
    warn "Note: removing the quirk will likely make the pointer stop moving again."
}

case $MODE in
    status) report_status ;;
    apply)  do_apply ;;
    revert) do_revert ;;
esac
