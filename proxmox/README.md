# Provisioning a runner VM on Proxmox

The node-side half: the VM itself, the firewall applied to it, and its
snapshots. Everything here is done in the Proxmox web console or on the node.

What happens *inside* the VM is
[docs/building-a-runner.md](../docs/building-a-runner.md), which is the same
on any hypervisor. Do this page first, up to the end of §3, then go there — it
sends you back for §4 twice, once for each snapshot.

That is deliberate. A script that runs `qm create` and writes into
`/etc/pve/firewall/` is exactly the kind of artifact people paste into a root
shell without reading, and the blast radius is the whole node — including
every VM on it that has nothing to do with CI. The steps below are short
enough to follow and specific enough to check, and you can see what you are
doing while you do it.

The in-VM half **is** a script: [`bin/dejima-ci-bootstrap`](../bin/dejima-ci-bootstrap).
Running that blind costs you a VM built to be lost.

One step here is not console work, because it cannot be: Proxmox schedules
backups but not rollbacks, so the cadence in §4 is a three-command cron entry.
It is printed in full and each part of it explained, which is the standard the
rest of this page is held to as well.

---

## What you are building

A machine to hand to an attacker.

The privileged runner gives job containers the Docker socket, which is
root-equivalent on their host. So the working assumption is not *if* but
*when*: a compromised job has root on this VM. Everything below follows from
taking that seriously rather than hoping.

Two VMs if you are following [the
tiering](../README.md#two-tiers-and-you-must-pick-one): one for the privileged
runner, one for the confined ones. Every step on this page is the same for
both - the tiers differ only in a flag, and that flag is in
[docs/building-a-runner.md](../docs/building-a-runner.md).

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
| General | Name | `oubliette`, or whatever you prefer |
| OS | ISO | Debian netinst, current stable |
| System | Qemu Agent | ✓ — and see the note below, the tick alone does nothing |
| Disks | Size | 64 GB is comfortable for image builds |
| CPU | Cores | 4 |
| Memory | | 8192 MB |
| Network | Bridge | your normal bridge |
| Network | **Firewall** | **✓ — this is the checkbox everything else depends on** |

The Firewall checkbox is easy to miss and easy to uncheck later without
noticing. If it is off, the per-VM rules do not apply to the interface and the
VM is simply on your LAN.

**Qemu Agent is two halves, and this is only one of them.** The tick opens a
virtio-serial channel on the host side; answering on it takes the
`qemu-guest-agent` package inside the guest, which the Debian install does not
add and nothing later in this runbook does either. Until it is installed the
VM's Summary pane shows no IP address — which is the field you would reach for
first if you let DHCP assign one. `sudo apt-get install -y qemu-guest-agent`
in the guest is the whole of it. Leaving it out is a defensible choice on a
machine built for a small surface; leaving it out while the box is ticked just
looks like the agent is broken.

**What a moving address does *not* break.** Not the firewall. Every rule in the
next section keys on a *destination*, except the SSH rule, which keys on *your*
management address — and Proxmox applies the whole set to this VM's tap device,
identified by VMID rather than by IP. Nothing anywhere names this VM by its own
address, so a rebuilt VM that comes up on a different one is still fully
firewalled.

What it breaks is you finding the machine: `ssh <you>@<vm-ip>` in §4, and every
later visit. That is reason enough to pin it.

---

## 3. The firewall rules

Every runner VM gets the same eight rules, whichever tier it is, so build them
once as a **security group** and apply that group to each. Two VMs with two
hand-entered copies is two chances to get the ordering wrong and one of them to
drift out of step later.

### Both tiers get these, for different reasons

Apply them to the confined tier as well as the privileged one. The rules are
identical; what differs is the job they are doing.

On the **privileged** tier this *is* the boundary. Its jobs hold the Docker
socket and run in the host's network namespace, so root on that VM is the
working assumption, and anything installed inside it can be removed by whatever
holds root. These rules are on the hypervisor, applied to the tap device, and
the guest cannot reach them.

On the **confined** tier the primary control is inside the VM: the job network,
its allowlisting resolver, and the DOCKER-USER rules. Those are real against a
job precisely because a job cannot reach them, and they decide job egress by
name and by address. The node firewall sits behind that as defence in depth. It
changes nothing the allowlist has already decided; it covers the case the
allowlist cannot, which is a job that escapes its container and reaches root on
the host. At that point what is left is this, and it is doing exactly what it
does on the other tier.

So: primary in the guest and defence in depth on the node for confined, nothing
in the guest and everything on the node for privileged.

**One thing to weigh before applying them to a confined host.** Rules 5–8 drop
every RFC1918 destination, including ones a *job* might legitimately want. If a
served repository declares an internal name in `.dejima/allowed-domains` — a
package mirror, an internal registry — the allowlist will resolve it and the
node firewall will drop the connection, which reads as the allowlist not
working. An internal NTP server is the same story. Give anything in that
position its own pinhole above the DROPs, or keep it off the allowlist so the
failure is at least honest about where it comes from.

And one value that has to agree: the resolver in rules 3–4 must be the same
address as `upstream` in `/etc/dejima-ci/config`, since that is where the
confined tier's dnsmasq forwards allowed queries. Point them at different
servers and every job fails to resolve while the host itself is fine.

### Build the group once

**Datacenter → Firewall → Security Group → Create**, named
`dejima-ci-hardener`. Then **Add** these to it, in this order:

| # | Direction | Action | Protocol | Dest. port | Source / Dest | Why |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | in | ACCEPT | tcp | 22 | **Source:** your management IP | The only way in |
| 2 | out | ACCEPT | tcp | 443 | **Dest:** forge IP | Fetch jobs, report results |
| 3 | out | ACCEPT | udp | 53 | **Dest:** nameserver IP | The forge's name is internal |
| 4 | out | ACCEPT | tcp | 53 | **Dest:** nameserver IP | Same, over TCP |
| 5 | out | DROP | — | — | **Dest:** `10.0.0.0/8` | |
| 6 | out | DROP | — | — | **Dest:** `172.16.0.0/12` | |
| 7 | out | DROP | — | — | **Dest:** `192.168.0.0/16` | The three that matter |
| 8 | out | DROP | — | — | **Dest:** `169.254.0.0/16` | Link-local, incl. metadata services |

### Then apply it, per VM

A security group carries **rules and nothing else**. The policies are not part
of it, so each VM still needs its own:

**VM → Firewall → Options**

| | |
| --- | --- |
| Firewall | `Yes` |
| Input Policy | `DROP` |
| Output Policy | `ACCEPT` |

Inbound denies by default — this VM offers no service anyone should reach, so
the exceptions are short and knowable. Outbound accepts by default, and the LAN
is denied explicitly by the group.

That asymmetry is deliberate, and it is worth resisting the obvious-looking
alternative: deny outbound too, then allow tcp/80, tcp/443 and udp/123. That
breaks things — apt during a first install, and anything else needing a port
nobody listed — and each breakage presents as a network fault rather than as a
firewall rule. It also buys almost nothing: this VM is assumed to be owned by
an attacker with root, and the guarantee being made is *reaches the internet,
not your network*, not *reaches only three ports*. Anyone who owns the box
tunnels over 443 like everybody else.

Deny-by-default earns its keep where the protected set is enumerable, which is
the LAN. The internet is not, and treating it as though it were gets you a rule
set that looks strict and only gets in the way.

Then **VM → Firewall → Add → Security Group**, and select
`dejima-ci-hardener`. That single entry is the whole rule set, in the order the
group defines, and it is the only firewall rule the VM needs.

Adding another runner later is that one step. The ordering below was got right
once, in one place, and cannot drift between hosts.

**Order matters within the group, and it is the one thing here that is easy to
get wrong.**
Rules are evaluated top to bottom and the first match wins. Your forge and
your resolver are *inside* the ranges rules 5–8 drop, so if either pinhole
ends up below them it is dead and the runner cannot reach the forge or resolve
anything. The console appends new rules at the bottom, so adding them in the
order above is all it takes — but check the list afterwards, and drag rows if
they are out of sequence.

Rules 2–4 are the entire remaining LAN exposure, and they are why "no LAN
access" is not literally true. Both destinations are pinned to one host and
one port.

Nothing follows rule 8. The public internet is reached by the default policy.

### Values that must agree

Three pairs here are entered in two places each, and each pair is silent when
the halves disagree. Read the real value off the machine rather than recalling
it — that is the whole of the advice, and every one of these is easy to get
wrong from memory.

| This | Must equal this | Read the truth from |
| --- | --- | --- |
| Rules 3–4's destination | The VM's **nameserver** | `grep nameserver /etc/resolv.conf` on the VM |
| Rule 2's destination | The forge's address | `getent hosts <forge-hostname>` |
| Rule 1's source | The host you SSH from | wherever you are sitting |

**Rules 3–4 want the nameserver, not the gateway.** They are the same address
on plenty of networks, which is exactly what makes this worth saying: using
the gateway works for some people and, for everyone else, blocks DNS while
leaving every other check passing. `ip route` gives you the gateway;
`/etc/resolv.conf` gives you the nameserver, and it is the second one that
belongs in these rules.

There is a fourth pair inside the VM, once `install.sh` has run: the
resolver's `listen-address` and the runner's `--dns=`. Same shape, same
silence. `install.sh` derives both from one answer for that reason.

### Check it, rather than assuming it

On the node, with the VM **running** — Proxmox builds these chains around the
VM's tap device, so a stopped VM has none and their absence would tell you
nothing:

```sh
# what is actually loaded right now
iptables -S | grep "tap<vmid>i0"

# what Proxmox would generate from the current config
pve-firewall compile | grep -B2 -A20 "tap<vmid>i0"
```

**What you are looking for.** Proxmox names the per-VM chains after the tap
interface — `tap<vmid>i0-IN` and `tap<vmid>i0-OUT` for the first NIC — and
your rules appear inside them, in the order you added them. In the `-OUT`
chain that means the three pinhole ACCEPTs first, then the four LAN DROPs,
then whatever Proxmox appends for the policy.

**What each failure looks like.**

| What you see | What it means |
| --- | --- |
| No `tap<vmid>i0` chains at all | The firewall is not applied to this VM. The NIC's Firewall checkbox, the VM's Firewall option, or the datacenter switch — check all three, in that order |
| Chains exist but hold none of your rules | The rules are on a different VM id, or were added at datacenter or node level rather than to this VM |
| A LAN DROP above a pinhole ACCEPT | The ordering trap. The runner will not reach the forge or resolve anything; drag the pinholes above the DROPs |
| Rules present and correct, DNS still failing | The address in rules 3–4 is not the VM's nameserver. The gateway is the usual wrong answer — see "Values that must agree" |

`pve-firewall status` is the quicker sanity check of whether the service is
running and enabled at all, but it says nothing about *these* rules — it is
the datacenter switch it reports on, not your eight lines.

**Both commands describe configuration.** They are worth reading, and they are
not proof: a rule that is loaded and a rule that does what you meant are
different claims. The checks from inside the VM below are the ones that test
behaviour, which is why they follow rather than replace this.

and from inside the VM, once it is up. Two of these must fail and two must
succeed, which is what makes the set diagnostic rather than reassuring:

Nothing here needs installing: `bash` can open a TCP connection on its own and
`getent` is part of libc, which matters on a machine you have not finished
setting up yet.

```sh
try() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null \
        && echo "  CONNECTED  $1:$2" || echo "  blocked    $1:$2"; }

try <some-other-lan-ip> 22     # must be blocked - any LAN host but the two
try <forge-ip> 443             # must connect
try deb.debian.org 80          # must connect - the public internet
getent hosts deb.debian.org && echo "  resolved" || echo "  DNS FAILED"
```

Read them together, because the pattern says which thing is wrong:

- **First one connects** → the firewall is not in force at all. Check the
  Network device's Firewall checkbox and the datacenter switch.
- **Second or third fails while the fourth works** → a pinhole is below the
  LAN DROPs. Check the rule order.
- **Everything fails** → the VM has no working route or DNS at all, which is
  a networking problem rather than a firewall one.

---

## 4. Snapshots and rollback

Three moments, and [docs/building-a-runner.md](../docs/building-a-runner.md)
says when each falls. The mechanics are the same for all of them: **VM →
Snapshots → Take Snapshot**, with *Include RAM* **unticked**.

| Name | When | What it is for |
| --- | --- | --- |
| `preflight` | after the OS is installed and its network verified, before anything is run on it | a known base to return to while iterating |
| `clean` | after the runner registers, before its first job | the state the rollback cadence returns to |

**Leave *Include RAM* unticked.** A snapshot with RAM restores the guest's
clock along with everything else, so a VM rolled back to last month believes it
is last month: TLS verification fails, apt rejects Release files as not yet
valid, and every timestamp a job writes is wrong. Nothing in this VM's memory
is worth resuming, and a rollback without RAM is smaller and faster besides.

Roll back from the same tab whenever you want it clean again. The snapshot
survives being rolled back to, so `clean` stays usable indefinitely —
`qm listsnapshot <vmid>` on the node shows it still there afterwards.

Two triggers:

- **After anything suspicious.** Not optional, and the reason to keep `clean`
  current enough that rolling back costs you nothing you mind losing.
- **On a cadence.** This is what bounds how long a foothold can live *without
  your having noticed it* — which is the case the first trigger cannot cover,
  and the reason the rest of this section exists.

### Automate the cadence

The reactive trigger depends on you noticing. The scheduled one does not, which
makes it the more valuable of the two — and the one that quietly stops
happening after the third week of remembering to do it by hand. Automate it now
or accept that it will not happen.

Proxmox schedules backups, not rollbacks, so there is no checkbox for this. It
is a cron entry on **the node** — which is also the only place it can live.
Nothing inside the VM can be relied on to revert the VM; that is the same
reason the firewall is on the node.

Create `/etc/cron.d/dejima-ci-rollback` on the node, substituting your VMID:

```
# Roll the runner VM back to its clean snapshot. Sundays, 04:00.
SHELL=/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
0 4 * * 0 root qm shutdown <vmid> --timeout 180 --forceStop 1 && qm rollback <vmid> clean && qm start <vmid>
```

Three things in that line are deliberate:

- **`qm shutdown` first, not `qm rollback` alone.** A snapshot without RAM
  cannot be rolled back into a running VM — Proxmox will not swap the disk out
  from under a live QEMU — and after the rollback the VM is left stopped, so
  the `qm start` is required rather than tidy. `--forceStop 1` pulls the plug
  if the guest has not gone down within the timeout, which is the correct
  outcome for a machine whose state you are about to discard anyway.
- **`&&`, not `;`.** If the rollback fails, the VM stays off. That is a CI
  outage, and it is the right one: the alternative is a VM that keeps taking
  untrusted-code jobs from a state you had decided to throw away. Fail closed
  and go look.
- **The `PATH` line.** `qm` lives in `/usr/sbin`, which is not on cron's
  default path. Without it the job fails every week with `qm: not found`.

**Pick an hour when nothing is running.** A rollback mid-job kills the job,
which shows up as a failed run and is re-runnable — annoying, not harmful, but
there is no reason to schedule it into the working day.

### Check that it is actually running

Belief that this is happening is worth nothing; the whole point is that it
happens while you are not watching.

- The node's **Tasks** pane at the bottom of the web console lists a
  `qmrollback` entry after each run. That is the check, and it needs no shell.
- `qm listsnapshot <vmid>` still shows `clean` — rollback does not consume it.
- If a run was interrupted the VM can be left locked, and every subsequent run
  fails on the lock. `qm unlock <vmid>` clears it.
- A rollback failing with the VM still running means `qm shutdown` returned
  before the guest was down. Put a `&& sleep 30` after it.

**Do not do this with a hookscript.** `qm set --hookscript` looks like the
right tool and is a trap: the pre-start and post-stop phases already hold the
VM's configuration lock, so a rollback from inside one deadlocks against
itself and times out. Cron, outside the VM's lifecycle, is the way.

### Refresh the baseline every month or two

A rollback reverts *everything* since the snapshot, including security updates.
`unattended-upgrades` catches up within a day of each boot, so the VM does not
stay unpatched — but the baseline it starts from is a week further behind every
week, and each rollback reopens whatever has been fixed since, until the timer
next runs.

So periodically: let it roll back, let it patch, reboot, confirm the runner is
*Online*, then **VM → Snapshots**, remove `clean` and take a fresh one under
the same name. That is also the moment to re-run `dejima-ci-bootstrap` if this
repository has moved on. (If a window with no snapshot at all bothers you, name
them by date instead and update the cron line — one more thing to keep in step,
which is why it is not the default suggestion here.)

Re-running `dejima-ci-bootstrap` after any rollback is safe — it is idempotent
— but should not be necessary, since the snapshot is taken after it ran. On a
`ci`-role host the allowlist is the same story from the other direction: it
reverts too, and `dejima-ci-allowlist.timer` pulls it current again on its own.

Whatever else reverts is cheap: Docker images have to be pulled again, so the
first job after a rollback is slower than the rest.
