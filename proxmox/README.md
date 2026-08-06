# Building the sacrificial runner VM

A runbook, not a script. Everything here is done in the Proxmox web console.

That is deliberate. A script that runs `qm create` and writes into
`/etc/pve/firewall/` is exactly the kind of artifact people paste into a root
shell without reading, and the blast radius is the whole node — including
every VM on it that has nothing to do with CI. The steps below are short
enough to follow and specific enough to check, and you can see what you are
doing while you do it.

The in-VM half **is** a script: [`bin/dejima-ci-bootstrap`](../bin/dejima-ci-bootstrap).
Running that blind costs you a VM built to be lost.

---

## What you are building

A machine to hand to an attacker.

The privileged runner gives job containers the Docker socket, which is
root-equivalent on their host. So the working assumption is not *if* but
*when*: a compromised job has root on this VM. Everything below follows from
taking that seriously rather than hoping.

Two VMs if you are following [the tiering](../README.md#register-scope-is-the-boundary-the-label-is-not):
one for the privileged runner, one for the ordinary ones. The steps are the
same; only the runner you register on each differs.

**The firewall goes on the node, not in the guest.** Root in the VM can flush
any rule set it can see. It cannot reach one applied to its own tap device.
Everything `dejima-ci-bootstrap` installs inside the VM is defence in depth —
real against a job that has not escaped its container, worth nothing against
one that has.

---

## 1. Check the datacenter firewall is on

**Do this first.** A per-VM firewall with the datacenter switch off is read
and enforced nowhere, and nothing about that is visible from the VM — it looks
exactly like a working setup.

**Datacenter → Firewall → Options → Firewall: `Yes`**

If you have to change it, check that nothing else on the node depended on
having no firewall. The datacenter default policy is `ACCEPT` in and out, so
turning it on does not by itself filter anything — but it is worth knowing
before you flip it rather than after.

---

## 2. Create the VM

**Create VM**, and the values that matter:

| Tab | Setting | Value |
| --- | --- | --- |
| General | Name | `oubliette` (or whatever you called it) |
| OS | ISO | Debian netinst, latest stable |
| System | Qemu Agent | ✓ |
| Disks | Size | 64 GB is comfortable for image builds |
| CPU | Cores | 4 |
| Memory | | 8192 MB |
| Network | Bridge | your normal bridge |
| Network | **Firewall** | **✓ — this is the checkbox everything else depends on** |

That last one is easy to miss and easy to uncheck later without noticing. If
it is off, the per-VM rules do not apply to the interface and the VM is simply
on your LAN.

Install Debian normally. **Static addressing**, not DHCP: the firewall names
this VM by address, and a lease that moves is a rule that no longer describes
it. Minimal install — no desktop, no print server, and you can leave the SSH
server out since `dejima-ci-bootstrap` configures it.

---

## 3. The firewall rules

**VM → Firewall → Options** first:

| | |
| --- | --- |
| Firewall | `Yes` |
| Input Policy | `DROP` |
| Output Policy | `DROP` |

Deny by default in both directions, then enumerate. The inverse — allow with a
list of denies — fails open for whatever the list forgot, which on this box is
the entire point.

Then **VM → Firewall → Add**, in this order. **Order matters**: rules are
evaluated top to bottom and the first match wins, so the two LAN pinholes have
to come before the LAN denies, and the LAN denies before the public allows.

| # | Direction | Action | Protocol | Dest. port | Source / Dest | Why |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | in | ACCEPT | tcp | 22 | **Source:** your management IP | The only way in |
| 2 | out | ACCEPT | tcp | 443 | **Dest:** forge IP | Fetch jobs, report results |
| 3 | out | ACCEPT | udp | 53 | **Dest:** resolver IP | The forge's name is internal |
| 4 | out | ACCEPT | tcp | 53 | **Dest:** resolver IP | Same, over TCP |
| 5 | out | DROP | — | — | **Dest:** `10.0.0.0/8` | |
| 6 | out | DROP | — | — | **Dest:** `172.16.0.0/12` | |
| 7 | out | DROP | — | — | **Dest:** `192.168.0.0/16` | The three that matter |
| 8 | out | DROP | — | — | **Dest:** `169.254.0.0/16` | Link-local, incl. metadata services |
| 9 | out | ACCEPT | tcp | 443 | — | Public HTTPS |
| 10 | out | ACCEPT | tcp | 80 | — | Public HTTP, for apt |
| 11 | out | ACCEPT | udp | 123 | — | NTP, or TLS starts failing oddly |

Rules 2–4 are **the entire remaining LAN exposure**, and they are why "no LAN
access" is not literally true: the runner cannot work without reaching the
forge, and the forge's name cannot resolve without a resolver. Both are pinned
to one host and one port.

Rules 9–11 are deliberately **not** an allowlist. Job containers already have
one, enforced inside the VM; duplicating it by IP here would break on every
CDN rotation, and against an attacker with root in the VM it would not hold
anyway. The guarantee is narrower and honest: *an attacker who owns this VM
reaches the internet, and not your network.*

`proxmox/firewall.fw.template` in this directory is the same rules as the file
Proxmox writes, if you would rather read them in one piece than click through
eleven rows. It is reference, not something to install — the console is the
supported path here.

### Check it, rather than assuming it

On the node:

```sh
pve-firewall compile | grep -A30 "vm-<vmid>"
```

and from inside the VM, once it is up — each of these should hang and fail:

```sh
# a LAN host that is not the forge or the resolver
timeout 5 nc -vz <some-other-lan-ip> 22 ; echo "rc=$?"
# the forge, which should succeed
timeout 5 nc -vz <forge-ip> 443 ; echo "rc=$?"
```

If the first one connects, the firewall is not in force. Check the Network
device's Firewall checkbox and the datacenter switch before anything else.

---

## 4. Bootstrap the VM

```sh
ssh <you>@<vm-ip>
git clone https://gitbox.example.com/branderson/dejima-ci-hardener.git
cd dejima-ci-hardener
sudo ./bin/dejima-ci-bootstrap --role runtime --mgmt <your-management-ip>
```

`--role ci` for the ordinary tier. That script installs packages, hardens
sshd, removes listeners a runner has no use for, sets up unattended security
upgrades, and runs `install.sh` for the allowlist, resolver and job firewall.

It does not register the runner — that needs a token from your forge — and it
does not enable the host's own egress policy until you have filled in
`/etc/dejima-ci/host-egress-allow`, because enabling it empty would cut the VM
off from the forge.

---

## 5. Snapshot it clean

The VM is worth losing, which is only true if losing it is cheap.

**VM → Snapshots → Take Snapshot**, named `clean`, described *bootstrapped,
before any job ran*. Take it **before** the first job — a snapshot taken later
preserves whatever that job left.

Roll back from the same tab whenever you want it clean again. Two triggers:

- **On a cadence.** Weekly is a reasonable starting point. This bounds how
  long a foothold can live without needing the VM rebuilt each time.
- **After anything suspicious.** This one is not optional, and it is the
  reason to keep the snapshot current enough that rolling back costs you
  nothing you mind losing.

Re-running `dejima-ci-bootstrap` after a rollback is safe — it is idempotent —
but should not be necessary, since the snapshot is taken after it ran.
