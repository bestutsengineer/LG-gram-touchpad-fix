#!/usr/bin/env bash
# shellcheck disable=SC2016,SC1091  # stub bodies are single-quoted on purpose; lib.sh is written at run time
# Regression tests for tp-triage.
#
# Nothing here touches the real touchpad, kernel or services: the script is
# run from a copy whose /sys, /proc, /run/lock, /run/user and /dev/input paths
# point into a throwaway directory, and every tool it calls (modprobe, i2cdetect,
# i2ctransfer, systemctl, journalctl, loginctl, notify-send, ...) is replaced
# by a stub that acts on that directory. No root needed.
#
# Usage: bash tests/run-tests.sh [path to tp-triage]
#        (default: ../bin/tp-triage; pass /usr/local/sbin/tp-triage to test
#        the installed copy)
#        TP_TEST_ONLY=<scenario> bash tests/run-tests.sh   run one scenario
#        and print its transcript
# Takes about four minutes. Exit status 0 means every check passed.
HERE=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
SCRIPT=$(readlink -f "${1:-$HERE/../bin/tp-triage}")
[ -r "$SCRIPT" ] || { echo "cannot read $SCRIPT" >&2; exit 2; }
T=$(mktemp -d /tmp/tp-triage-test.XXXXXX)
trap 'pkill -P $$ 2>/dev/null; pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0

# setup <name>: build a fake machine in $F with the touchpad unbound, the
# driver module not loaded and the chip silent. (A real boot has the module
# loaded by udev; "loaded" below adds that.)
setup() {
  F=$T/$1
  ELAN=$F/sys/bus/i2c/devices/i2c-ELAN0E03:00
  I2CDRV=$F/sys/bus/i2c/drivers/i2c_hid_acpi
  PCI=$F/sys/bus/pci/devices/0000:00:15.0
  PCIDRV=$F/sys/bus/pci/drivers/intel-lpss
  mkdir -p "$F"/{bin,logs,run/lock,dev/input,proc/bus/input,proc/sys/kernel/random,sys/module,sys/class/dmi/id} \
    "$ELAN" "$F/sys/bus/i2c/devices/i2c-0" "$I2CDRV" "$PCI/power" "$PCIDRV" \
    "$F/sys/kernel/debug/pinctrl/INT34C5:00" "$F/sys/power/suspend_stats" "$F/sys/bus/pci"
  echo 16Z90P-G.AA54A > "$F/sys/class/dmi/id/product_name"
  echo on > "$PCI/power/control"; echo active > "$PCI/power/runtime_status"; echo D0 > "$PCI/power_state"
  ln -s "$PCIDRV" "$PCI/driver"
  echo 5 > "$F/sys/power/suspend_stats/success"; echo "s2idle [deep]" > "$F/sys/power/mem_sleep"
  echo "1000.0 900.0" > "$F/proc/uptime"; echo deadbeef-0000 > "$F/proc/sys/kernel/random/boot_id"
  : > "$F/proc/bus/input/devices"; : > "$F/journal"; : > "$F/kmsg"; : > "$F/unit-starts"
  echo "  1:   0   0  IO-APIC  1-edge  i8042" > "$F/proc/interrupts"
  echo "pin 179 (UART0_RXD) 264:INT34C5:00 GPIO 0x80100100 0x00003076 0x00000000 [LOCKED full]" \
    > "$F/sys/kernel/debug/pinctrl/INT34C5:00/pins"

  cat > "$F/lib.sh" <<EOF
F=$F; ELAN=$ELAN; I2CDRV=$I2CDRV; PCI=$PCI; PCIDRV=$PCIDRV
attach() {  # the kernel binding a chip that answers
  [ -d "\$ELAN" ] && [ -e "\$F/chip_alive" ] && [ -d "\$F/sys/module/i2c_hid_acpi" ] || return 1
  ln -sfn "\$I2CDRV" "\$ELAN/driver"
  printf 'I: Bus=0018\nN: Name="ELAN0E03:00 04F3:3191 Touchpad"\nH: Handlers=mouse2 event99 \n\n' > "\$F/proc/bus/input/devices"
  grep -q ELAN0E03 "\$F/proc/interrupts" || echo " 118:   100   0  IR-IO-APIC  118-fasteoi   ELAN0E03:00" >> "\$F/proc/interrupts"
}
detach() { rm -f "\$ELAN/driver"; : > "\$F/proc/bus/input/devices"; sed -i '/ELAN0E03/d' "\$F/proc/interrupts"; }
EOF
  . "$F/lib.sh"
  stub() { printf '#!/bin/bash\n. %s/lib.sh\n%s\n' "$F" "$2" > "$F/bin/$1"; chmod +x "$F/bin/$1"; }
  stub id 'if [ "$1" = -u ]; then echo 0; else /usr/bin/id "$@"; fi'
  stub logger 'shift 3; echo "$*" >> "$F/journal"'
  stub journalctl 'cat "$F/kmsg"'
  stub lsmod 'ls "$F/sys/module"'
  stub modinfo 'echo /lib/modules/fake/kernel/drivers/hid/i2c-hid/i2c-hid.ko.xz'
  stub systemctl 'case "$1" in is-enabled) echo enabled;; is-active) echo active;; show) echo success;; start) echo "$2" >> "$F/unit-starts";;
  suspend) echo suspend >> "$F/suspends"; ( sleep 1; n=$(cat "$F/sys/power/suspend_stats/success"); echo $((n+1)) > "$F/sys/power/suspend_stats/success" ) >/dev/null 2>&1 & ;;
esac'
  stub rtcwake 'exit 0'
  stub loginctl 'case "$1" in list-sessions) echo "2 1000 tester seat0 100 user tty2 no -" ;;
  show-session) case "$*" in *Active*) echo yes;; *Class*) echo user;; *Type*) echo wayland;; *User*) echo 1000;; *Name*) echo tester;; esac ;; esac'
  stub runuser 'echo "$*" >> "$F/notifications"; case " $* " in *" --print-id "*) echo 42;; esac'
  stub notify-send 'echo "direct $*" >> "$F/notifications"'
  mkdir -p "$F/run/user/1000"; python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$F/run/user/1000/bus"; : > "$F/notifications"
  stub i2cdetect 'case " $* " in *" -a "*) echo "$*" >> "$F/scan.log"
    if [ -e "$F/wake_on_scan" ]; then need=$(cat "$F/wake_on_scan"); [ "$(wc -l < "$F/scan.log")" -ge "${need:-1}" ] && touch "$F/chip_alive"; fi ;; esac
echo "     0  1  2  3  4  5"; if [ -e "$F/chip_alive" ]; then echo "10:                15"; else echo "10:                --"; fi'
  stub i2ctransfer 'case "$*" in *r1@0x00*) echo "$*" >> "$F/addr0.log"
    if [ -e "$F/wake_on_addr0" ]; then need=$(cat "$F/wake_on_addr0"); [ "$(wc -l < "$F/addr0.log")" -ge "${need:-1}" ] && { touch "$F/chip_alive"; exit 0; }; fi
    exit 1 ;;
  *w1@0x00\ 0x06*) echo "$*" >> "$F/gc.log"
    if [ -e "$F/wake_on_gc" ]; then [ "$(wc -l < "$F/gc.log")" -ge "$(cat "$F/wake_on_gc")" ] && { touch "$F/chip_alive"; exit 0; }; fi
    exit 1 ;;
  *@0x00*) exit 1 ;; esac
if [ -e "$F/chip_alive" ]; then echo "0x00 0x00"; else echo "Error: Sending messages failed: Remote I/O error" >&2; exit 1; fi'
  stub modprobe '
case "$1" in -r) rm -rf "$F/sys/module/$2"; [ "$2" = i2c_hid_acpi ] && detach; exit 0 ;; esac
mkdir -p "$F/sys/module/i2c_hid_acpi" "$F/sys/module/i2c_hid"
[ -e "$F/no_autoprobe" ] || { ( sleep 0.3; attach ) >/dev/null 2>&1 & }
exit 0'

  # FIFOs stand in for the sysfs control files; a reader acts on each write.
  for p in "$I2CDRV/bind" "$I2CDRV/unbind" "$PCIDRV/unbind" "$PCIDRV/bind" "$PCI/remove" "$F/sys/bus/pci/rescan"; do mkfifo "$p"; done
  serve() { while true; do cat "$1" >/dev/null; "$2"; done; }
  on_pci_unbind() { rm -f "$PCI/driver"; detach; rm -rf "$ELAN" "$F/sys/bus/i2c/devices/i2c-0"; }
  on_pci_bind() {
    ln -sfn "$PCIDRV" "$PCI/driver"; mkdir -p "$ELAN" "$F/sys/bus/i2c/devices/i2c-0"
    [ -e "$F/revive_on_cycle" ] && touch "$F/chip_alive"
    sleep 0.15; attach
  }
  on_pci_remove() { detach; rm -rf "$ELAN" "$F/sys/bus/i2c/devices/i2c-0"; }
  on_pci_rescan() { mkdir -p "$ELAN" "$F/sys/bus/i2c/devices/i2c-0"; [ -e "$F/revive_on_rescan" ] && { sleep 2; touch "$F/chip_alive"; }; }
  { serve "$PCI/remove" on_pci_remove & serve "$F/sys/bus/pci/rescan" on_pci_rescan &
    serve "$I2CDRV/bind" attach & serve "$I2CDRV/unbind" detach &
    serve "$PCIDRV/unbind" on_pci_unbind & serve "$PCIDRV/bind" on_pci_bind & } > /dev/null 2>&1

  sed -e "s#/sys/#$F/sys/#g" -e "s#/proc/#$F/proc/#g" -e "s#/run/lock/#$F/run/lock/#g" -e "s#/run/user/#$F/run/user/#g" \
    -e "s#/dev/input/#$F/dev/input/#g" \
    "$SCRIPT" > "$F/tp-triage"; chmod +x "$F/tp-triage"
}

# World-building helpers, used after setup.
loaded()   { mkdir -p "$F/sys/module/i2c_hid_acpi"; }
alive()    { touch "$F/chip_alive"; }
healthy()  { loaded; alive; attach; }
dead_but_bound() { healthy; rm "$F/chip_alive"; }       # what a failed resume leaves behind
reported() { echo 17 > "$F/run/lock/tp-triage.reported"; }   # an earlier run already sent "not responding", as popup 17
resume_error() { printf '%s\n' 'PM: suspend entry (deep)' 'i2c_hid_acpi i2c-ELAN0E03:00: PM: failed to resume async: error -121' 'PM: suspend exit' > "$F/kmsg"; }
# Interrupt counter: 60/s under a live chip (a finger), 4000/s under a bound dead one (a storm).
ticker() { ( while true; do
    cur=$(awk '/ELAN0E03/ { print $2 }' "$F/proc/interrupts" 2>/dev/null)
    if [ -n "$cur" ]; then
      if [ -e "$F/chip_alive" ]; then cur=$((cur+12)); else cur=$((cur+800)); fi
      sed -i "s/^ 118:  *[0-9]*/ 118:   $cur/" "$F/proc/interrupts" 2>/dev/null
    fi
    sleep 0.2; done ) > /dev/null 2>&1 & }

run() { # run <stdin-text> [script args...]; sets RC, ELAPSED
  local input=$1; shift
  local start; start=$(date +%s.%N)
  printf '%s' "$input" | PATH="$F/bin:$PATH" TP_TRIAGE_LOG_DIR="$F/logs" TP_TRIAGE_AUTO_RETRY_SECONDS=12 JOURNAL_STREAM='' \
    "$F/tp-triage" "$@" > "$F/out" 2>&1
  RC=$?
  ELAPSED=$(echo "$(date +%s.%N) - $start" | bc)
}

check() { # check <name> <expected rc> <max seconds> [regex that must appear in the journal]...
  local name=$1 want=$2 max=$3 ok=1 why=; shift 3
  [ "$RC" -eq "$want" ] || { ok=0; why+=" rc=$RC(want $want)"; }
  (( $(echo "$ELAPSED <= $max" | bc) )) || { ok=0; why+=" took ${ELAPSED}s(max $max)"; }
  for re in "$@"; do
    if [ "${re:0:1}" = '!' ]; then grep -qE "${re:1}" "$F/journal" && { ok=0; why+=" unexpected[${re:1}]"; }
    else grep -qE "$re" "$F/journal" || { ok=0; why+=" missing[$re]"; }; fi
  done
  if [ "$ok" -eq 1 ]; then pass=$((pass+1)); printf 'PASS  %-34s rc=%s %.1fs\n' "$name" "$RC" "$ELAPSED"
  else fail=$((fail+1)); printf 'FAIL  %-34s%s\n' "$name" "$why"; sed 's/^/      /' "$F/journal" | tail -15; fi
  [ -n "$ONLY" ] && sed -E 's/^\[[^]]*\] //' "$F/out"
  pkill -P $$ 2>/dev/null; pkill -f "$F/" 2>/dev/null; wait 2>/dev/null
}

notes() { # notes <expected count> [regex the notification must match]
  local n; n=$(wc -l < "$F/notifications")
  if [ "$n" -ne "$1" ]; then echo "      FAIL: $n notifications, expected $1"; fail=$((fail+1))
  elif [ -n "${2:-}" ] && ! grep -qE -- "$2" "$F/notifications"; then echo "      FAIL: notification text: $(cat "$F/notifications")"; fail=$((fail+1)); fi
}
scenario() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
ONLY=${TP_TEST_ONLY:-}

# --- the unit's mode ------------------------------------------------------
if scenario auto-healthy; then setup auto-healthy; healthy; reported
  run '' --auto; check auto-healthy 0 1.5; notes 0
  [ -z "$(ls "$F/logs")" ] || { echo "      FAIL: a healthy --auto run left a log"; fail=$((fail+1)); }
  [ ! -e "$F/run/lock/tp-triage.reported" ] || { echo "      FAIL: a healthy touchpad left the report marker"; fail=$((fail+1)); }; fi
# The kernel is still probing the touchpad when udev starts the unit.
if scenario auto-probe-in-flight; then setup auto-probe-in-flight; loaded; alive
  ( sleep 0.7; attach ) > /dev/null 2>&1 &
  run '' --auto; check auto-probe-in-flight 0 2.5; notes 0
  [ -z "$(ls "$F/logs")" ] || { echo "      FAIL: waiting for the kernel's probe left a log"; fail=$((fail+1)); }
  [ -L "$ELAN/driver" ] || { echo "      FAIL: not bound"; fail=$((fail+1)); }; fi
# Boot with a silent chip: the kernel's own probe has failed, the driver is loaded.
if scenario auto-boot-probed-silent; then setup auto-boot-probed-silent; loaded; touch "$F/wake_on_addr0"
  run '' --auto; check auto-boot-probed-silent 0 5.5 'wake result=answers stage=read_addr_0x00 tries=1' 'load_and_bind result=bound' '!command_start label=\[load'
  notes 1 'Touchpad recovered.*chip had not started'; fi
if scenario auto-boot-alive; then setup auto-boot-alive; alive
  run '' --auto; check auto-boot-alive 0 2 'load_and_bind result=bound_on_load' '!wake '; notes 0; fi
if scenario auto-boot-silent-wake; then setup auto-boot-silent-wake; touch "$F/wake_on_addr0" "$F/no_autoprobe"
  run '' --auto; check auto-boot-silent-wake 0 4 'wake result=answers stage=read_addr_0x00' 'load_and_bind result=bound'; notes 1 'Touchpad recovered.*chip had not started'; fi
if scenario auto-wake-second-try; then setup auto-wake-second-try; loaded; echo 2 > "$F/wake_on_addr0"
  run '' --auto; check auto-wake-second-try 0 5.5 'wake result=answers stage=read_addr_0x00 tries=2 acked=1'; fi
if scenario auto-wake-by-scan; then setup auto-wake-by-scan; loaded; touch "$F/wake_on_scan"
  run '' --auto; check auto-wake-by-scan 0 7.5 'read_addr_0x00 tries=10 acked=0 result=silent' 'wake result=answers stage=scan_all_addresses'; fi
if scenario auto-wake-late; then setup auto-wake-late; loaded; echo 14 > "$F/wake_on_addr0"
  run '' --auto; check auto-wake-late 0 12 'wake result=answers stage=read_addr_0x00 retry=4 ' 'load_and_bind result=bound'
  notes 2 'urgency=critical.*Touchpad not responding'
  grep -qE 'urgency=normal.*--replace-id=42 Touchpad recovered' "$F/notifications" || { echo "      FAIL: no \"recovered\" in place of popup 42: $(tail -1 "$F/notifications")"; fail=$((fail+1)); }
  [ ! -e "$F/run/lock/tp-triage.reported" ] || { echo "      FAIL: late recovery left the report marker"; fail=$((fail+1)); }; fi
if scenario auto-boot-dead; then setup auto-boot-dead
  run '' --auto; check auto-boot-dead 1 30 'auto_retry tries=20 ' 'auto_retry gave_up tries=24' 'wake stage=general_call_reset' 'wake stage=scan_all_addresses' 'wake result=silent' '!controller_cycle'; notes 1 'Touchpad not responding'
  [ "$(cat "$F/run/lock/tp-triage.reported" 2>/dev/null)" = 42 ] || { echo "      FAIL: a reported failure did not leave its popup id in the marker"; fail=$((fail+1)); }; fi
# The later tries keep all three wakes: the reset every fifth try, the scan every twentieth.
if scenario auto-wake-late-reset; then setup auto-wake-late-reset; loaded; echo 2 > "$F/wake_on_gc"
  run '' --auto; check auto-wake-late-reset 0 12 'wake stage=general_call_reset rc=1' 'wake result=answers stage=general_call_reset retry=5 ' 'load_and_bind result=bound'
  notes 2 'replace-id=42 Touchpad recovered'; fi
if scenario auto-wake-late-scan; then setup auto-wake-late-scan; loaded; echo 2 > "$F/wake_on_scan"
  run '' --auto; check auto-wake-late-scan 0 20 'wake result=answers stage=scan_all_addresses retry=20 ' 'load_and_bind result=bound'; notes 2; fi
# A second trigger for the same fault (resume, then the lid) must not notify again.
if scenario auto-dead-already-reported; then setup auto-dead-already-reported; loaded; reported
  run '' --auto; check auto-dead-already-reported 1 32.5 'notify skipped reason=already_reported' 'wake result=silent'; notes 0; fi
if scenario auto-recovered-after-report; then setup auto-recovered-after-report; loaded; reported; touch "$F/wake_on_addr0"
  run '' --auto; check auto-recovered-after-report 0 5.5 'wake result=answers'; notes 1 '--replace-id=17 Touchpad recovered'
  [ ! -e "$F/run/lock/tp-triage.reported" ] || { echo "      FAIL: recovery left the report marker"; fail=$((fail+1)); }; fi
if scenario auto-resume-failed; then setup auto-resume-failed; dead_but_bound; resume_error; touch "$F/wake_on_addr0"
  run '' --auto; check auto-resume-failed 0 3 'device_unbind rc=0' 'raw_read addr=0x15 rc=1' 'wake result=answers stage=read_addr_0x00' 'load_and_bind result=bound'; notes 1 'urgency=normal.*Touchpad recovered.*did not come back after resume'; fi
if scenario auto-storm; then setup auto-storm; dead_but_bound; touch "$F/wake_on_addr0"; ticker
  run '' --auto; check auto-storm 0 4 'device_unbind' 'wake result=answers'; notes 1 'Touchpad recovered.*flooding'; fi
if scenario auto-resume-dead; then setup auto-resume-dead; dead_but_bound; resume_error
  run '' --auto; check auto-resume-dead 1 30 'auto_retry gave_up' 'wake result=silent' '!controller_cycle'; notes 1 'Touchpad not responding.*after resume'; fi
if scenario auto-force; then setup auto-force; healthy
  run '' --auto --force; check auto-force 0 3 'device_unbind rc=0' 'load_and_bind result=bound' '!wake '; notes 0; fi
if scenario auto-no-client-yet; then setup auto-no-client-yet; rm -rf "$ELAN"
  run '' --auto; check auto-no-client-yet 0 1; [ -z "$(ls "$F/logs")" ] || { echo "      FAIL: left a log"; fail=$((fail+1)); }; fi
if scenario auto-old-boot-flag; then setup auto-old-boot-flag; alive
  run '' --boot; check auto-old-boot-flag 0 2 'run_start mode=auto' 'load_and_bind result=bound_on_load'; fi
if scenario auto-suspend-early-wake; then setup auto-suspend-early-wake; loaded
  run '' --auto --suspend=3; check auto-suspend-early-wake 1 42.5 'suspend_reroll resumed'
  [ "$(wc -l < "$F/suspends")" -eq 1 ] || { echo "      FAIL: suspended $(wc -l < "$F/suspends") times after an early wake"; fail=$((fail+1)); }; fi
if scenario auto-lock-busy; then setup auto-lock-busy
  ( exec 9> "$F/run/lock/tp-triage.lock"; flock 9; sleep 3 ) > /dev/null 2>&1 & sleep 0.3
  run '' --auto; check auto-lock-busy 0 1.5; fi

# --- the lid watcher ------------------------------------------------------
# The lid switch is a FIFO fed with 24-byte input events: 16 bytes of time,
# then type, code and value.
if scenario watch-lid; then setup watch-lid; healthy
  printf 'I: Bus=0019 Vendor=0000 Product=0005 Version=0000\nN: Name="Lid Switch"\nP: Phys=PNP0C0D/button/input0\nH: Handlers=event0 \nB: SW=1\n\n' >> "$F/proc/bus/input/devices"
  mkfifo "$F/dev/input/event0"; exec 7<> "$F/dev/input/event0"
  lid_event() { python3 -c 'import struct, sys; sys.stdout.buffer.write(struct.pack("<qqHHi", 0, 0, *map(int, sys.argv[1:])))' "$@" >&7; }
  PATH="$F/bin:$PATH" TP_TRIAGE_LID_RECHECK_SECONDS=1 "$F/tp-triage" --watch-lid > "$F/out" 2>&1 7>&- &
  watcher=$!
  sleep 0.5
  lid_event 5 0 1; lid_event 0 0 0                    # closed, and the sync event that follows every change
  lid_event 5 1 0; lid_event 0 0 0                    # another switch (tablet mode) is not the lid
  sleep 1.5; after_close=$(wc -l < "$F/unit-starts")
  lid_event 5 0 0; lid_event 0 0 0                    # opened
  sleep 3.5; after_open=$(wc -l < "$F/unit-starts")
  exec 7>&-; wait "$watcher"; RC=$?; ELAPSED=0
  check watch-lid 1 1
  [ "$after_close" -eq 0 ] || { echo "      FAIL: closing the lid started the unit $after_close times"; fail=$((fail+1)); }
  [ "$after_open" -eq 2 ] && [ "$(sort -u "$F/unit-starts")" = tp-triage.service ] \
    || { echo "      FAIL: opening the lid started the unit $after_open times (want 2): $(tr '\n' ' ' < "$F/unit-starts")"; fail=$((fail+1)); }
  grep -q 'Watching .*/dev/input/event0' "$F/out" || { echo "      FAIL: watcher output: $(cat "$F/out")"; fail=$((fail+1)); }; fi
if scenario watch-lid-no-switch; then setup watch-lid-no-switch; healthy
  run '' --watch-lid; check watch-lid-no-switch 1 1; grep -q 'No readable lid switch' "$F/out" || { echo "      FAIL: output: $(cat "$F/out")"; fail=$((fail+1)); }; fi

# --- interactive ----------------------------------------------------------
if scenario healthy; then setup healthy; healthy; ticker
  run ''; check healthy 0 4 'activity_result=working'; fi
if scenario no-finger-decline; then setup no-finger-decline; healthy
  run 'n'; check no-finger-decline 1 8 'activity_result=too_low' 'decision=no' '!device_unbind'; fi
if scenario resume-failed-wake; then setup resume-failed-wake; dead_but_bound; resume_error; touch "$F/wake_on_addr0"; ticker
  run ''; check resume-failed-wake 0 5 'step_start label=\[Rebind' 'wake result=answers' 'activity_result=working' '!controller_cycle'; notes 0; fi
if scenario storm-wake; then setup storm-wake; dead_but_bound; touch "$F/wake_on_addr0"; ticker
  run ''; check storm-wake 0 6 'activity_result=interrupt_storm' 'wake result=answers' 'activity_result=working'; fi
if scenario silent-cycle-revives; then setup silent-cycle-revives; loaded; touch "$F/revive_on_cycle"; ticker
  run ''; check silent-cycle-revives 0 14 'wake result=silent' 'controller_cycle result=bound_with_input' 'activity_result=working'; fi
if scenario silent-nothing-works; then setup silent-nothing-works; loaded
  run $'n\nn\nn\n'; check silent-nothing-works 1 25 'wake result=silent' 'controller_cycle result=failed' 'question=\[Suspend for 10.*decision=no' 'question=\[Reload.*decision=no' 'question=\[Re-enumerate.*decision=no' 'recovery_failed'; fi
if scenario ladder-order; then setup ladder-order; loaded
  run $'n\ny\nn\n'; check ladder-order 1 32 'label=\[Module reload\]' 'unload i2c_hid_acpi' '!pci_remove'
  order=$(grep -oE 'label=\[(Load the driver|Cycle the I2C|Module reload)|question=\[(Suspend|Reload|Re-enumerate)' "$F/journal" | awk '!seen[$0]++' | tr '\n' ' ')
  case $order in *'Load the driver'*'Cycle the I2C'*'Suspend'*'Reload'*'Module reload'*'Re-enumerate'*) ;; *) echo "      FAIL: ladder order: $order"; fail=$((fail+1)) ;; esac; fi
if scenario rescan-revives; then setup rescan-revives; loaded; touch "$F/revive_on_rescan"; ticker
  run $'n\nn\ny\n'; check rescan-revives 0 40 'pci_remove rc=0' 'pci_rescan rc=0' 'activity_result=working'; fi
if scenario lock-busy; then setup lock-busy
  ( exec 9> "$F/run/lock/tp-triage.lock"; flock 9; sleep 3 ) > /dev/null 2>&1 & sleep 0.3
  run ''; check lock-busy 75 1.5; fi
if scenario status; then setup status; healthy
  run '' --status; check status 0 1.5
  { grep -q 'driver     : bound' "$F/out" && grep -q 'lid watcher: tp-triage-lid-watch.service active' "$F/out"; } || { echo "      FAIL: status output"; fail=$((fail+1)); }; fi
if scenario bad-option; then setup bad-option
  run '' --bogus; check bad-option 64 1; fi

if scenario test-notify; then setup test-notify
  run '' --test-notify; check test-notify 0 1; notes 1 'Touchpad notification test'; fi
if scenario hibernate-restore-failed; then setup hibernate-restore-failed; dead_but_bound; touch "$F/wake_on_addr0"
  printf '%s\n' 'PM: hibernation: hibernation entry' 'i2c_hid_acpi i2c-ELAN0E03:00: PM: failed to restore async: error -121' 'PM: hibernation: hibernation exit' > "$F/kmsg"
  run '' --auto; check hibernate-restore-failed 0 3 'device_unbind' 'wake result=answers'; notes 1 'after resume'; fi

[ -n "$ONLY" ] || echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
