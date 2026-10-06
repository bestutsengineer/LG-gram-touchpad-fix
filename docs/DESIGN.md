# Design and maintenance notes

How tp-triage works, what was measured to get there, and what to watch when
changing it. The README covers installing and using it.

Everything here was observed on one LG Gram 16Z90P-G.AA54A (BIOS T2ZF0320,
Fedora 44, kernel 7.1) over about seven weeks in 2026. Counts are given as
"x of y" so their weight is visible; several are small.

## Files

| File | Role |
|---|---|
| `bin/tp-triage` | The whole tool: state display, wake, bind, recovery ladder, finger test, unattended mode, lid watcher, notification |
| `systemd/tp-triage.service` | Oneshot that runs `tp-triage --auto` |
| `systemd/tp-triage-lid-watch.service` | Keeps `tp-triage --watch-lid` running, which starts the oneshot when the lid is opened |
| `udev/80-lg-gram-elan-touchpad.rules` | Pins the I2C controller's runtime power management to `on`; starts the unit when the touchpad's I2C client appears |
| `install.sh`, `uninstall.sh` | Deploy and remove the four files above |
| `tests/run-tests.sh` | Runs the script against a fake `/sys` and `/proc` |

Hardware names used throughout:

| Item | Value |
|---|---|
| Touchpad | ACPI `ELAN0E03` at `\_SB.PC00.I2C0.TPD0`, HID `04F3:3191` |
| Linux client | `i2c-ELAN0E03:00`, bus 0, address `0x15`, driver `i2c_hid_acpi` |
| Controller | PCI `0000:00:15.0`, Intel LPSS I2C #0 (`8086:a0e8`, subsystem `1854:0400`), driver `intel-lpss` |
| Interrupt | PCH pin 179, IRQ 118, level-triggered, active low |
| Lid switch | ACPI `PNP0C0D`, input device named `Lid Switch` |

The touchpad is the only device on I2C bus 0.

## The fault

After the controller has lost power it often does not start properly. Measured
100 minutes into one such episode, with the driver unbound:

| Probe | Result |
|---|---|
| I2C0 SDA/SCL pads (PCH pins 187/188) | native mode, both idle high: the bus is muxed and pulled up |
| Interrupt pad | held low, against the pad's own 20k pull-up |
| Read or write at `0x15` | not acknowledged |
| Read of every address from `0x08` to `0x77` | nothing acknowledged |
| Embedded-controller memory, all 256 bytes | identical before and after recovery, apart from battery and temperature readings |

So the controller is powered and waiting, not switched off. ACPI keeps
reporting `_STA=15` and `D0` throughout, which says nothing about it.

Under a bound driver the stuck interrupt line is an interrupt storm of about
5,000 interrupts a second. The kernel's resume path then fails with
`failed to change power setting` and `PM: failed to resume async: error -121`,
and leaves the driver bound to a controller that does not answer.

### When the state changes by itself

From 393 suspend/resume cycles where the state before and after is known:

| Suspend length | Was working | Was dead (driver still bound) |
|---|---|---|
| under 2 min | 170 of 170 stayed working | 141 of 143 stayed dead |
| 2 to 7 min | 5 of 5 stayed working | 2 of 3 stayed dead |
| 7 to 60 min | 6 of 12 stayed working | 3 of 3 revived |
| 1 to 8 h | 13 of 20 stayed working | 2 of 10 revived |
| over 8 h | 5 of 17 stayed working | 4 of 10 revived |

A suspend shorter than about seven minutes leaves the controller as it was. A
longer one power-cycles it, and it then comes up working roughly half the time
whatever its state before (33 of 72). Boots follow the same pattern (35
boots):

| Boot | Controller present at boot |
|---|---|
| Warm reboot | 9 of 10: the state carries over |
| Cold boot | 3 of 5 |
| Cold boot after all power was removed (real-time clock reset) | 0 of 8 |

### Dead when the lid is opened

Twice the touchpad was found dead with no suspend and no boot before it. Both
times the laptop had been left awake with the lid closed, for 181 and for 11
minutes (the lid switch is set to do nothing on this machine), and the
interrupt storm was found 21 and 90 seconds after the lid was opened. In the
second case the interrupt counter shows that the storm cannot have started
more than about 20 seconds before the lid was opened, so the controller was
alive for nearly all of the time the lid was closed. The kernel logs nothing
when this happens: the driver stays bound and its interrupt handler fails
silently.

It does not happen every time. On the day of the second failure the lid had
already been closed, awake, for 140, 17 and 5 minutes, and the touchpad was
alive after each. Over the seven weeks the lid was closed for five minutes or
more with the laptop awake about 120 times; how many of those ended with a
dead touchpad is not known, because only the two that were followed by a run
of this script left a trace.

What the lid does to the controller is not known. The wake brings it back the
same way.

## The wake

A read addressed to I2C address `0x00` is acknowledged by a controller in the
dead state, and it then answers at `0x15` within milliseconds, with the
interrupt line released.

- It was found by accident: an `i2cdetect -a` scan, the first to include the
  reserved addresses below `0x08`, was acknowledged at `0x00` and then at
  `0x15`, after 66 probes of `0x15` in the preceding 19 seconds had failed.
- Since then it has recovered 5 of 5 failures.
- Of the 6 individual reads at `0x00` sent to a dead controller, 5 were
  acknowledged. The one that was not was followed by a general-call write
  (also not acknowledged) and, within a second, by a read that was. Hence the
  retry loop.

A plausible reading is that the controller sits in its bootloader on the
default address until a host addresses it there. That is an inference. Nothing
here proves it, and the wake is used because it works, not because it is
understood.

`wake_chip` in the script has three stages and logs which one worked:

1. up to 10 reads at `0x00`, a tenth of a second apart, checking `0x15` after
   each
2. a read of every address (`i2cdetect -y -a -r 0`), which is what was running
   the first time
3. a general-call reset (`0x06` written to `0x00`)

Only the first has been needed.

## How the service is started

`tp-triage.service` is a oneshot with four triggers:

| Event | Trigger |
|---|---|
| Boot | `WantedBy=multi-user.target`, and the udev rule below |
| The I2C client appears (boot, or the controller being re-enumerated) | udev: `TAG+="systemd"`, `ENV{SYSTEMD_WANTS}+=` on `ACTION=="add"` |
| Resume from suspend, hibernation, hybrid sleep, suspend-then-hibernate | `WantedBy=` and `After=` the four sleep targets, which systemd reaches once the system is back |
| The lid is opened | `tp-triage-lid-watch.service` starts it one second and eleven seconds later |

Observed after resume from suspend: the unit starts about 0.03 seconds after
the kernel logs `PM: suspend exit` and, with a healthy touchpad, is finished
0.4 seconds later. The hibernation targets use the same mechanism and have not
been seen in practice.

### Boot

The stock driver is left to the kernel. When the I2C client appears udev loads
`i2c_hid_acpi` for it, and the driver binds by itself if the controller
answers. On a machine with an encrypted disk that happens in the initramfs,
before the disk is unlocked. When the controller is silent the kernel's probe
fails without a message and nothing retries it; the unit then finds the
touchpad unbound, wakes the controller and binds.

udev starts the unit for the same event that makes it load the driver, so the
unit can arrive while the kernel is still probing. An unbound touchpad whose
driver is loaded therefore gets two seconds to become bound before it is
treated as a fault.

This path was rehearsed on the running system, with the driver unloaded and
the device's `add` event replayed: udev loaded the driver 0.12 seconds after
the event, the touchpad was bound when the unit started, and the unit exited
without doing anything. A real boot this way has not been observed yet.

An earlier version blacklisted `i2c_hid_acpi` so that the unit loaded it later
in the boot. That is why the script loads the module with `modprobe
--ignore-install` and why the test suite still covers a boot with the driver
not loaded.

### The lid

Nothing in udev or systemd fires when the lid is opened, so
`tp-triage-lid-watch.service` keeps `tp-triage --watch-lid` running. It reads the
lid switch's input device through `od`, which blocks until the switch moves,
and on each "open" starts the oneshot twice: after one second and again ten
seconds later, because it is not known how long after the lid the controller
goes. A healthy check costs half a second each time.

That `od` prints each switch event as its own line the moment it happens was
checked against a real kernel input device (a test switch created through
uinput). Observed with the real lid: the unit started 1.0 and 11.4 seconds
after the lid was opened and, with a healthy touchpad, took 0.4 seconds each
time. An opening with a dead touchpad behind it has not been seen since the
watcher was added.

## The unattended run

`tp-triage --auto`, in order:

1. Exit if the I2C client does not exist yet; udev starts the unit again when
   it appears.
2. Decide whether anything needs doing, without touching the bus:
   - the last resume failed: the kernel log of this boot has `PM: failed to
     resume` (or `restore`/`thaw` after hibernation) for the touchpad after the
     last sleep entry, with no touchpad input device created since
   - or the interrupt counter is rising faster than 1,000 a second
   - or the touchpad is not bound, and with its driver loaded has stayed
     unbound for two seconds
   If none holds, exit with status 0, having logged nothing.
3. Take the lock. If another run holds it, exit 0.
4. If the driver is bound, unbind only `i2c_hid_acpi` from the device and note
   what a raw read returns. Pin the controller, load the driver if needed,
   wake the controller if it is silent, bind.
5. Send one notification if the touchpad was really faulty (see below).
6. If it is still not bound, repeat step 4 twice, five seconds apart. Every
   successful wake so far came 28 seconds or more after the resume, so the
   controller may not be ready for it straight away.

It never cycles the controller, reloads modules or suspends, unless
`--suspend` was given.

### The notification

One per run, sent after the first attempt so that it can say how that went:
"Touchpad recovered", or a critical "Touchpad not responding". It is sent only
when a fault was actually found: a failed resume, a storm, or a controller
that had to be woken. A touchpad that only needed its driver bound is not
reported.

Several triggers can fire for one fault: waking the laptop by opening the lid
starts the unit from the sleep target and twice from the lid watcher. So a
"not responding" notification leaves `/run/lock/tp-triage.reported` behind,
and while that file exists later runs try again without notifying. It is
removed as soon as the touchpad is seen working, by any run.

The unit runs as root, so the notification goes through `runuser` and
`notify-send` to the session bus of the user who owns the active graphical
session. Before login there is no such session and it is skipped.

## The interactive ladder

Ordered by how often each step has worked. Every step ends with the wake and a
bind, and the finger test follows any step that binds the driver.

| # | Step | Record | Notes |
|---|---|---|---|
| 1 | Wake, bind. For a bound touchpad, unbind the HID driver first | 5 of 5 failures | |
| 2 | Unbind and rebind `intel-lpss` on the controller | 3 of 13 | Fixed one of two interrupt storms and re-attached a controller that was already alive. Never revived a silent one (0 of 9), and as the first step on a storming touchpad it lost the controller twice |
| 3 | Suspend 10 minutes with an RTC alarm | 9 of 23 long suspends revived a dead controller | As a scripted step 0 of 3: the laptop woke by itself after 257, 5 and 5 seconds. An early wake is reported and not followed by another suspend |
| 4 | Unload and reload `i2c_hid_acpi` and `i2c_hid` | 0 of 12 | |
| 5 | Remove the controller from the PCI bus and rescan | 0 of 12 | Twice the driver bound 10 to 15 seconds after the rescan and the touchpad produced no interrupts |

Steps 3 to 5 ask first. They are kept so that there is something left to try
if the wake ever stops working.

### The finger test

A bound driver with an input device is not proof of a working touchpad, so
the interactive mode measures interrupts:

- one second with fingers off: more than 500 interrupts is a storm
- up to five seconds of movement: 20 interrupts are enough, and the test ends
  as soon as they have arrived

A finger produces about 120 interrupts a second. `libinput debug-events` for
the touchpad is recorded into the log during both phases when it is available.

## What does not work

- **Waiting and retrying binds.** 40 bind attempts on a silent controller all
  failed at once. When the controller is alive it binds about 0.15 seconds
  after its driver or controller appears.
- **Kernel-side changes.** A patched `i2c_hid` that skipped the HID sleep
  command before suspend and a module that disabled ACPI power management for
  the touchpad made no difference to how often resumes failed.
- **ACPI.** The touchpad's power resource only sets or clears the bit that
  routes its interrupt pad to the IOAPIC. ACPI exposes no power or reset line
  for it, and the firmware locks the pad configuration, so the pads cannot be
  driven from Linux either.
- **Embedded-controller flags.** Three touchpad-related flags reachable
  through the vendor's WMI interface were toggled and restored, with no
  effect.
- **A general-call reset**, sent to a dead controller: not acknowledged.
- **Short suspends, warm reboots, removing all power, s2idle instead of S3.**
- **Delaying the bind at boot.** An earlier version kept the driver from
  loading with a modprobe blacklist and loaded it from its own service later
  in the boot. Boots still came up with a silent controller, and a silent
  controller does not start answering by being left alone.

## Trust boundaries

- The script runs as root and trusts sysfs, procfs, the kernel log and its
  own files. It evaluates no input: there is no configuration file, and the
  `TP_TRIAGE_*` environment variables are checked to be numbers or used only
  as a directory name.
- The notification text is fixed. The user name it is sent to comes from
  logind.
- Paths, the bus number and the device name are constants, and the installer
  and the script both refuse to run on a machine whose DMI product name does
  not match.
- Log files are world-readable by design, so that a failure can be looked at
  without root.

## Changing it safely

```bash
bash tests/run-tests.sh
bash install.sh
```

### The test suite

`tests/run-tests.sh` copies the script, rewrites every `/sys/`, `/proc/`,
`/run/lock/`, `/run/user/` and `/dev/input/` path in it to point into a
temporary directory, and puts stubs for the tools it calls first in `PATH`.
The sysfs control files (`bind`, `unbind`, `remove`, `rescan`) are FIFOs with
a small reader behind each that changes the fake tree the way the kernel
would, and the lid switch is a FIFO fed with packed input events. Marker files
in the fake tree set the scenario: whether the controller is alive, whether it
wakes on the first or the nth read at `0x00`, on a scan, after a controller
cycle, and so on.

Each scenario checks the exit status, an upper bound on the run time, lines
that must or must not appear in the script's journal output, and the number
of notifications sent. To add one, copy a neighbouring block.

What the suite cannot show is how the real controller behaves. Anything that
changes what is sent on the bus needs a real failure to confirm it.

### Things that will bite

- **No `RemainAfterExit` in the unit.** A unit left "active (exited)" is not
  started again, so it would run at boot and never after a resume. The
  installer stops the unit after installing, which also clears an instance
  left behind by an older unit file.
- **The udev rule must match `ACTION=="add"` only.** Matching `bind` and
  `unbind` events as well makes systemd start the unit every time a driver is
  attached or detached, including by the script itself.
- **A healthy unattended run must stay off the bus.** It runs at every boot
  and resume; the checks in step 2 above read only sysfs, procfs and the
  journal.
- **The script has to live outside `/home`.** With SELinux enforcing, systemd
  will not execute a script from a home directory. Hence the copy in
  `/usr/local/sbin` and the note the script prints when that copy differs from
  the one being run.
- **Address `0x00` needs `-a`.** `i2cdetect` and `i2ctransfer` skip the
  reserved addresses below `0x08` unless told otherwise, which is why years of
  ordinary bus scans would never have found the wake.
- **Rebinding the controller resets its `power/control` to `auto`**, and it
  suspends again within seconds. The script pins it straight after the bind.
- **Every controller cycle or rescan makes the kernel print** `sysfs: cannot
  create duplicate filename '/kernel/software_nodes/node1/i2c-0'` with a stack
  trace. It is harmless.
- **Log lines are written once.** Under the unit, standard output already is
  the journal and `logger` is skipped. The check compares `JOURNAL_STREAM`
  with the script's own stderr through file descriptor 3, because inside a
  command substitution standard output is a pipe.
- **`strtonum` and `and()` are gawk functions.** They are used only for the
  interrupt-line readout, which prints `unknown` with another awk.
- **One notification per run, and one per fault.** `FAULT` is set in two
  places, where the fault is detected and in `wake_chip`, and `notify_fault`
  is called once. Across runs the marker file described under "The
  notification" does the rest; a new exit path that leaves a working touchpad
  has to remove it.
- **The lid watcher parses raw input events.** One event is 24 bytes on
  x86-64 (16 on a 32-bit kernel), and `od -w24 -tu2` turns it into one line of
  twelve words. `-v` matters, because without it `od` folds repeated lines
  into `*`, and so does `stdbuf -oL`, without which `od` holds its output back
  in a buffer.
- **The unit must wait for the kernel's own probe.** Without the two seconds
  in `needs_recovery` a unit started by udev alongside the driver load would
  unbind a touchpad that was just coming up.
- **New absolute paths need the test suite's rewrite list extended**, and new
  external tools need a stub, or the tests will act on the real system.
