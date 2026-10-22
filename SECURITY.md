# Security

## What runs with administrator rights

Tether installs two root LaunchDaemons, only after you enter your administrator password.

The helper, `/Library/PrivilegedHelperTools/local.tether.helper`
(`/Library/LaunchDaemons/local.tether.helper.plist`), only ever:

- runs `pmset -a disablesleep 0|1`, `pmset -b|-c lowpowermode <value>` and, as a fallback,
  `pmset sleepnow`, with fixed arguments;
- asks the system to sleep (`IOPMSleepSystem`);
- reads power, lid, battery and thermal state from IOKit;
- writes its status, stats and log under `/Library/Application Support/Tether` and
  `/Library/Logs/Tether`;
- removes itself, the watchdog, their files, and the `tether` links and per-user login items that
  point into Tether.app, once Tether.app has been gone for 10 minutes (dragged to the Trash). The
  app path it watches must end in `.app/Contents/MacOS/Tether`, so a hand-edited control file
  can't aim this clean-up elsewhere.

Per-user cleanup opens each parent directory without following symbolic links, checks the
fixed CLI or login-item leaf, and unlinks only that entry without recursive deletion.
Unrelated files and paths with symbolic-link parents are left untouched.

It makes no network connections and runs no program other than `pmset` and, when removing
itself, `launchctl bootout`.

The watchdog, `/Library/PrivilegedHelperTools/local.tether.watchdog`
(`/Library/LaunchDaemons/local.tether.watchdog.plist`), is a short shell script launchd runs every
minute. It reads the power source, `SleepDisabled` and the age of the helper's status file, and
only ever runs `pmset -a disablesleep 0` (turning sleep back on) when the helper has gone silent
while sleep is off on battery.

## Diagnostics

The diagnostic report (Settings › System › Diagnostics, `tether diagnose`) is written to your
Desktop or clipboard and sent nowhere. It contains Tether's settings, state, records and logs,
the relevant lines of `pmset -g log` and the names of apps holding power assertions; your home
folder, user name, full name and the Mac's name are masked. Read it before sharing it.

## Inputs

The app and the `tether` command talk to the helper through
`/Library/Application Support/Tether/control.json`, owned by root and writable by the `admin`
group, so only administrators can change settings. The folder itself is root's alone (root:wheel
0755): nobody else can add, remove or replace files in it, so the helper's files can't be swapped
for links. The file is rewritten in place and a link or a hard link is refused; the helper writes
its own files through a fresh, unpredictable temporary file that is renamed into place, never
through a path somebody else chose. Files over 4 MB aren't read.

The helper treats control.json as untrusted: safety limits are clamped again so a hand-edited file
can only make them stricter, and a hold never survives a helper restart.

2.0.0 left the folder writable by the `admin` group while the helper wrote its files through
predictable temporary names, so a process running as an administrator could, without the password,
have the helper overwrite or change the mode of other files as root. 2.0.1 fixes this: installing
it (or the new helper's first start) takes the folder back and removes anything unexpected in it.

`tether://` URLs can turn clamshell mode on or off, start or end a battery hold, or sleep the Mac.
Browsers ask before opening them. `tether run` is not available as a URL.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting (Security › Report a vulnerability) on
[jukqaz/tether](https://github.com/jukqaz/tether) rather than a public issue.
