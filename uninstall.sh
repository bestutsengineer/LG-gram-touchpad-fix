#!/usr/bin/env bash
# Remove tp-triage: the two units, the udev rule and the script. Logs in
# /var/log/tp-triage are kept.
#
# Usage: bash uninstall.sh
set -eu

unit=tp-triage.service
watch=tp-triage-lid-watch.service

if [[ $(id -u) -ne 0 ]]; then
    exec sudo -- bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/uninstall.sh" "$@"
fi

systemctl disable --now "$watch" "$unit" 2> /dev/null || true
rm -f "/etc/systemd/system/$unit" "/etc/systemd/system/$watch" /usr/local/sbin/tp-triage \
    /etc/udev/rules.d/80-lg-gram-elan-touchpad.rules /run/lock/tp-triage.reported
systemctl daemon-reload
udevadm control --reload

echo 'Removed. Logs were kept; delete them with:'
echo '  rm -r /var/log/tp-triage'
