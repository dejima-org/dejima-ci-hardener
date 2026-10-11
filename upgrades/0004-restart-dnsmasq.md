---
version: 4
title: New allowlist names take effect without waiting for a restart
layers: guest
tiers: confined
snapshot: required
---

# v4: new allowlist names take effect without waiting for a restart

Confined tier only. One config line and one restart.

## Why

`render` applied a changed allowlist with `systemctl reload dnsmasq`. A reload
is a SIGHUP, and dnsmasq does not re-read its config files on one: it clears its
cache and re-reads hosts files only. A name added to a declaration was written to
`/etc/dnsmasq.d/ci-allow.conf` and never loaded, so jobs failed to resolve it
until dnsmasq happened to restart.

Nothing reported it. `show` prints the file and `check` compares the file, and
both were right about the file.

## 1. Change the command

In `/etc/dejima-ci/config`:

```
reload = systemctl restart dnsmasq
```

Or re-run `sudo ./install.sh`, which now offers that in place of the old value.

## 2. Restart dnsmasq once

```sh
sudo systemctl restart dnsmasq
```

**`render` does not do this for you.** It runs the command only when the
allowlist changes, and on a host that has been rendering all along the file is
already current. Whatever was added since dnsmasq last started stays unresolvable
until this.

**Re-snapshot before this tier's next scheduled rollback**, or the old command
comes back with it.
