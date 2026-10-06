#!/usr/bin/env bash
# Install tp-triage system-wide: the script, the two systemd units and the
# udev rule. Needs root and re-runs itself under sudo.
# Safe to run again after changing anything in this directory.
#
# Usage: bash install.sh
set -eu

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
model=16Z90P-G.AA54A
client=/sys/bus/i2c/devices/i2c-ELAN0E03:00
unit=tp-triage.service
watch=tp-triage-lid-watch.service

if [[ $(id -u) -ne 0 ]]; then
    exec sudo -- bash "$here/install.sh" "$@"
fi

# The bus number, the I2C addresses and the PCI IDs are written into the
# script for one laptop model. On anything else it would talk to the wrong
# devices, so this refuses to install anywhere but on that machine.
found=$(cat /sys/class/dmi/id/product_name 2> /dev/null || true)
if [[ $found != "$model" || ! -e $client ]]; then
    echo "tp-triage is for the LG Gram $model with the ELAN0E03 touchpad." >&2
    echo "Found product '${found:-unknown}'; $client is $([[ -e $client ]] && echo present || echo missing)." >&2
    echo "Nothing was installed. See 'Other models' in README.md." >&2
    exit 1
fi

missing=()
for tool in i2cdetect i2ctransfer modprobe flock awk od stdbuf journalctl systemctl udevadm; do
    command -v "$tool" > /dev/null || missing+=("$tool")
done
if ((${#missing[@]})); then
    echo "Missing required tools: ${missing[*]}" >&2
    echo "i2cdetect and i2ctransfer come from the i2c-tools package." >&2
    exit 1
fi
for tool in notify-send libinput rtcwake; do
    command -v "$tool" > /dev/null || echo "Optional tool not found: $tool (see Requirements in README.md)"
done

bash -n "$here/bin/tp-triage"
install -m 755 "$here/bin/tp-triage" /usr/local/sbin/tp-triage
install -m 644 "$here/systemd/$unit" "/etc/systemd/system/$unit"
install -m 644 "$here/systemd/$watch" "/etc/systemd/system/$watch"
install -m 644 "$here/udev/80-lg-gram-elan-touchpad.rules" /etc/udev/rules.d/80-lg-gram-elan-touchpad.rules
# With SELinux, files copied out of a home directory can keep its label, and
# systemd may then not execute the script.
if command -v restorecon > /dev/null; then
    restorecon /usr/local/sbin/tp-triage "/etc/systemd/system/$unit" "/etc/systemd/system/$watch" \
        /etc/udev/rules.d/80-lg-gram-elan-touchpad.rules || true
fi

systemctl daemon-reload
systemctl reenable "$unit"
# A unit that is still "active" is not started again after resume. Stopping it
# clears an instance left behind by an older version of the unit.
systemctl stop "$unit"
systemctl enable "$watch"
systemctl restart "$watch"
udevadm control --reload
udevadm trigger --action=change /sys/bus/pci/devices/0000:00:15.0 || true
udevadm trigger --action=add "$client"
udevadm settle --timeout=5 || true

echo 'Installed. Current state: tp-triage --status'
