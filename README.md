# tp-triage

Brings back the ELAN touchpad of the LG Gram 16Z90P when it is dead after a
suspend, at boot or when the lid is opened. It does so automatically, and
gives you a terminal tool to look at the touchpad's state and recover it by
hand.

| Part | What it does |
|---|---|
| `tp-triage` | Shows the touchpad's state, wakes its controller, rebinds the driver, and checks with a finger test that it really works |
| `tp-triage.service` | Runs `tp-triage --auto` at boot, after every resume and when the lid is opened. Does nothing when the touchpad is healthy |
| `tp-triage-lid-watch.service` | Watches the lid switch and starts the service above each time the lid is opened |
| udev rule | Starts the service when the touchpad's I2C device appears, and keeps its I2C controller out of runtime suspend |

It was written for one laptop and has only been tested on that one. Read
"Is this your problem?" before installing.

## The problem

On this laptop the touchpad controller often fails to start after it has lost
power: after a suspend longer than about seven minutes, or after a cold boot.
Twice it was also found dead when the lid was opened on a laptop that had
stayed awake with it closed. It then ignores its I2C address `0x15` and holds
its interrupt line low. From Linux that looks like one of these:

| What you see | Kernel log |
|---|---|
| Dead pointer after resume, often with an interrupt storm of about 5,000 interrupts a second | `i2c_hid_acpi i2c-ELAN0E03:00: failed to change power setting.` and `PM: failed to resume async: error -121` |
| No touchpad after boot | nothing; the driver never binds |
| Dead pointer after opening the lid, with the same interrupt storm | nothing; the driver stays bound |

Reloading modules, rebinding the driver, re-enumerating the I2C controller,
ACPI methods and short suspends do not bring it back. One I2C read addressed
to `0x00` does: the controller acknowledges it and answers at `0x15`
milliseconds later. `tp-triage` sends that read, retrying if it is not
acknowledged, and then binds the driver.

This is a workaround. The cause is in the controller or the laptop's firmware,
and there is no firmware update that fixes it.

## Is this your problem?

All of these should be true:

- `cat /sys/class/dmi/id/product_name` prints `16Z90P-G.AA54A`
- `ls /sys/bus/i2c/devices/` lists `i2c-ELAN0E03:00`
- after a failed resume, `journalctl -k -b | grep ELAN0E03` shows the two
  kernel lines above

The installer and the script check the first two and refuse to run anywhere
else. With the touchpad dead you can try the wake by hand before installing
anything (`i2c-tools` needed; on this laptop the touchpad is the only device
on I2C bus 0):

```bash
sudo modprobe i2c-dev
# only if the driver is still bound (dead after resume):
echo i2c-ELAN0E03:00 | sudo tee /sys/bus/i2c/drivers/i2c_hid_acpi/unbind
sudo i2cdetect -y -r 0 0x15 0x15        # "--": the controller is silent
sudo i2ctransfer -y -a 0 r1@0x00        # the wake; repeat if it reports an error
sudo i2cdetect -y -r 0 0x15 0x15        # "15": it answers again
echo i2c-ELAN0E03:00 | sudo tee /sys/bus/i2c/drivers/i2c_hid_acpi/bind
```

If `--` turns into `15` and the pointer comes back, this project automates
exactly that.

## Requirements

- LG Gram `16Z90P-G.AA54A` with the `ELAN0E03` touchpad (HID `04F3:3191`).
  Developed on BIOS `T2ZF0320`, Fedora 44, kernel 7.1, KDE Plasma 6.
- systemd, udev, `bash`, coreutils, kmod, util-linux
- `i2c-tools` for `i2cdetect` and `i2ctransfer`
- Optional: `notify-send` (libnotify) for the desktop notification, `libinput`
  (libinput tools) to record what libinput sees during the finger test, `gawk`
  for the interrupt-line readout in `--status`

## Install

```bash
git clone https://github.com/bestutsengineer/LG-gram-touchpad-fix.git
cd LG-gram-touchpad-fix
bash install.sh
```

The installer asks for root through `sudo`, then copies four files and enables
the two services:

| Installed file | From |
|---|---|
| `/usr/local/sbin/tp-triage` | `bin/tp-triage` |
| `/etc/systemd/system/tp-triage.service` | `systemd/` |
| `/etc/systemd/system/tp-triage-lid-watch.service` | `systemd/` |
| `/etc/udev/rules.d/80-lg-gram-elan-touchpad.rules` | `udev/` |

Nothing else on the system is changed: the stock kernel driver is used as it
is. To remove everything again: `bash uninstall.sh`.

## Use

```bash
tp-triage                                     # interactive: state, recovery, finger test
tp-triage --status                            # read-only state, no root needed
tp-triage --test-notify                       # show the notification the service sends
journalctl -u tp-triage.service -b            # when the service ran
journalctl -u tp-triage-lid-watch.service -b  # the lid watcher
journalctl -t tp-triage -b                    # what it did when it had to act
```

Run `tp-triage` when the pointer is dead. It asks for root through `sudo`,
shows the state, recovers, and then asks you to move a finger so it can tell a
working touchpad from one that is only bound.

```
--- state ---
  i2c client : present
  driver     : bound
  input node : yes
  _STA       : 15
  module     : loaded
  chip @0x15 : owned by the driver (not probed)
  INT line   : high
  controller : control=on runtime=active state=D0
  unit       : tp-triage.service enabled, last result success
  lid watcher: tp-triage-lid-watch.service active
  last resume: no touchpad error
```

`INT line: low` together with `chip @0x15: SILENT` is the dead state.

## What the service does

It runs `tp-triage --auto` at boot, whenever the touchpad's I2C device
appears, after every resume from suspend or hibernation, and one second and
eleven seconds after the lid is opened.

1. If the touchpad is bound, its last resume did not fail and it is not
   flooding the system with interrupts, it exits at once and logs nothing.
   This takes about 0.4 seconds and sends nothing on the I2C bus.
2. Otherwise it detaches the HID driver if it is bound, wakes the controller
   through address `0x00` if it is silent, and binds the driver.
3. If the touchpad was really faulty it sends **one** desktop notification
   to whoever is logged in at the screen: "Touchpad recovered", or "Touchpad
   not responding" if that first attempt did not bind it. A healthy touchpad
   sends none, and neither does one that only needed its driver bound. A
   failure that has been reported is not reported again by the next trigger.
4. If the first attempt failed it tries twice more, five seconds apart, and
   then gives up. It never does anything more disruptive than that.

At boot the kernel binds the touchpad by itself when the controller answers,
and the service then has nothing to do.

## Recovery steps

Interactive `tp-triage` works down this list, most successful step first, and
runs the finger test after any step that gets the driver bound.

| # | Step | Asks first | Record so far |
|---|---|---|---|
| 1 | Wake the controller through address `0x00`, then bind | no | recovered 5 of 5 failures |
| 2 | Cycle the `intel-lpss` driver on the I2C controller, wake, bind | no | 3 of 13 |
| 3 | Suspend for 10 minutes to power-cycle the controller, wake, bind | yes | long suspends revived 9 of 23 dead controllers; the step itself 0 of 3, because the laptop woke early each time |
| 4 | Reload the `i2c_hid` modules | yes | 0 of 12 |
| 5 | Remove the I2C controller from the PCI bus and rescan | yes | 0 of 12 |

The numbers come from one laptop over about seven weeks. They are in
[docs/DESIGN.md](docs/DESIGN.md) with what was measured and how.

`tp-triage --auto --suspend[=N]` adds step 3 to an unattended run. `--force`
makes either mode recover even when the touchpad looks fine.

## Limitations

- One laptop model, tested on one unit. The I2C bus number, addresses, PCI
  IDs and the pin number of the interrupt line are written into the script.
- It is a workaround. After a bad resume the pointer is dead for a second or
  two until the service has run.
- A touchpad that dies while the laptop is open and awake would not be
  noticed until the next resume or opening of the lid. That has not been seen.
- The lid trigger was added after the second failure of that kind and has not
  had a real one to repair yet.
- Before anyone has logged in there is nobody to notify, so a failure at boot
  is only logged.
- The suspend step is unreliable: the laptop has to stay asleep for the whole
  ten minutes, and here it did not.
- Recovery after hibernation uses the same path as after suspend but has only
  been exercised in the test suite.

### Other models

Other LG Gram models with the same symptoms may have the same fault, but
nothing here has been tried on them. Try the commands under "Is this your
problem?" first, with your own bus number. If the wake works, the
constants to change are at the top of `bin/tp-triage`, in `install.sh` and in
the udev rule.

## Security notes

- The services and the interactive tool run as root. They read sysfs, procfs
  and the kernel log, write to the driver `bind`/`unbind` files of the
  touchpad and (interactive only) of its I2C controller, load `i2c_hid_acpi`,
  and talk to I2C bus 0 with `i2cdetect` and `i2ctransfer`. There is no
  network access.
- The lid watcher reads the lid switch's input device. That device reports
  the switch and nothing else; no keyboard is read.
- The notification is sent with `runuser` as the user who owns the active
  graphical session, through that user's session bus.
- Logs go to `/var/log/tp-triage/` and are world-readable. They hold the
  touchpad's state, excerpts of the kernel log about it and, for the finger
  test, a few seconds of `libinput debug-events` for the touchpad only (pointer
  motion, no keystrokes). The newest 200 are kept.
- `TP_TRIAGE_LOG_DIR` and the other `TP_TRIAGE_*` variables are read from the
  environment. They are there for calibration and for the test suite; do not
  set them in the service's environment.
- The installer and the script refuse to run on any other machine, because
  the bus number, the addresses and the PCI IDs in them belong to this model.

Found a problem? Please open an issue.

## Development

```bash
bash tests/run-tests.sh                            # tests bin/tp-triage
bash tests/run-tests.sh /usr/local/sbin/tp-triage  # tests the installed copy
```

The suite takes about four minutes, needs no root and never touches the real
touchpad: the script runs from a copy whose `/sys`, `/proc`, `/run` and
`/dev/input` paths point into a temporary directory, with every tool it calls
replaced by a stub. It needs `bc` and `python3` besides the usual shell tools. All four
scripts are `shellcheck`-clean.

How it works, what was measured and the things that will bite when you change
it are in [docs/DESIGN.md](docs/DESIGN.md).

## License

MIT, see [LICENSE](LICENSE).
