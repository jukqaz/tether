# Security

## What runs with administrator rights

Tether installs one helper, `/Library/PrivilegedHelperTools/local.tether.helper`, as a root
LaunchDaemon (`/Library/LaunchDaemons/local.tether.helper.plist`). It is installed only after you
enter your administrator password, and it only ever:

- runs `pmset -a disablesleep 0|1`, `pmset -b|-c lowpowermode <value>` and, as a fallback,
  `pmset sleepnow`, with fixed arguments;
- asks the system to sleep (`IOPMSleepSystem`);
- reads power, lid, battery and thermal state from IOKit;
- writes its status, stats and log under `/Library/Application Support/Tether` and
  `/Library/Logs/Tether`.

It makes no network connections and runs no program other than `pmset`.

## Inputs

The app and the `tether` command talk to the helper through
`/Library/Application Support/Tether/control.json`, owned by root and writable by the `admin`
group, so only administrators can change settings. The helper treats the file as untrusted:
safety limits are clamped again so a hand-edited file can only make them stricter, and a hold
never survives a helper restart.

`tether://` URLs can turn Tether on or off, start or end a battery hold, sleep the Mac or turn the
screen off. Browsers ask before opening them. `tether run` is not available as a URL.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting (Security › Report a vulnerability) on
[jukqaz/tether](https://github.com/jukqaz/tether) rather than a public issue.
