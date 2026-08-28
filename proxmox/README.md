# Provisioning a runner VM on Proxmox

The node-side half: the VM, the firewall applied to it, and its snapshots. The
in-VM half is [docs/building-a-runner.md](../docs/building-a-runner.md), the
same on any hypervisor.

## The whole job

**Already have a runner?** This page builds one. To bring an existing VM
forward, start at [Updating](../README.md#updating-an-existing-runner) — the
upgrade notes name the rules to change rather than having you re-read the table
below.

Four steps, and the two pages interleave — follow this order rather than either
page top to bottom.

| | Do this | Where | Roughly |
| --- | --- | --- | --- |
| 1 | Turn the datacenter firewall on | §1 below | one setting |
| 2 | Create the VM | §2 below | one form |
| 3 | Install Debian | [guest §1](../docs/building-a-runner.md#1-install-debian) | the usual |
| 4 | **Build the rules, apply them, verify** | §3 below | **the substance of this page** |
| 5 | Finish the guest setup | [guest §2 onward](../docs/building-a-runner.md#2-addressing-leave-it-on-dhcp) | it sends you back to §4 twice, once per snapshot |

**Everything except step 4 is short.** Step 4 is ten firewall rules entered into
a form, three policy settings, and two verification passes. If you have done it
before, [the rule table](#build-the-group-once) is the whole of it.

**Two VMs if you are following
[the tiering](../README.md#two-tiers-and-you-must-pick-one)** — one privileged,
one for the confined runners. Every step here is identical for both; the tiers
differ only in a flag, and that flag is in the guest runbook.

**The rules go on after the OS is installed, not before.** The Debian installer
takes its address by DHCP whatever you pin it to afterwards, and a lease needs a
reply back in. Apply the group first, without the DHCP pair from §3, and the
installer has no network at all — which presents as a broken mirror or a dead
link rather than as a firewall you switched on ten minutes earlier. Ticking the
Firewall checkbox in §2 is safe on its own.

## What you are building

**A machine to hand to an attacker.**

The privileged runner gives job containers the Docker socket, which is
root-equivalent on their host. So the working assumption is not *if* but *when*:
a compromised job has root on this VM.

**The firewall goes on the node, not in the guest.** Root in the VM can flush
any rule set it can see. It cannot reach one applied to its own tap device.
Everything `dejima-ci-bootstrap` installs inside the VM is defence in depth —
real against a job that has not escaped its container, worth nothing against one
that has.

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

**Qemu Agent is two halves, and this tick is one of them.** It opens a
virtio-serial channel on the host side; answering on it takes the
`qemu-guest-agent` package inside the guest, which `dejima-ci-bootstrap`
installs and which tells you if this tick is missing. Leave it on: without the
channel the agent has nothing to attach to, the Summary pane shows no address,
`qm shutdown` falls back to hoping ACPI is acted on, and a snapshot of a
running VM stays crash-consistent.

**What a moving address does *not* break.** Not the firewall. Every rule in the
next section keys on a *destination*, except the SSH rule, which keys on *your*
management address — and Proxmox applies the whole set to this VM's tap device,
identified by VMID rather than by IP. Nothing anywhere names this VM by its own
address, so a rebuilt VM that comes up on a different one is still fully
firewalled.

What it breaks is you finding the machine: `ssh <you>@<vm-ip>`, and every later
visit. That is reason enough to pin it.

---

## Now install the OS, then come back

The VM exists and has no operating system. Go to
**[docs/building-a-runner.md §1](../docs/building-a-runner.md#1-install-debian)**,
install Debian, and return here for §3.

Nothing else from the guest runbook is needed yet. Coming back with a booted VM
is what makes the rest of this page checkable rather than assumed.

---

## 3. The firewall rules

Every runner VM gets the same ten rules, whichever tier it is, so build them
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

**One thing to weigh before applying them to a confined host.** Rules 5–9 drop
every private destination, including ones a *job* might legitimately want. If a
served repository declares an internal name in `.dejima/allowed-domains` — a
package mirror, an internal registry — the allowlist will resolve it and the
node firewall will drop the connection, which reads as the allowlist not
working. An internal NTP server is the same story. Give anything in that
position its own pinhole above the DROPs, or keep it off the allowlist so the
failure is at least honest about where it comes from.

Rule 10 has the same shape and one extra wrinkle: it also drops IPv6 egress to
the *internet*, not only to your network, because the family goes whole. In
practice that changes nothing for a confined job, since `dejima-ci-firewall`
rejects IPv6 on the job bridge for the same reason. It could matter to a
privileged job that fetches from a v6-only host. If you hit that, the honest fix
is a pinhole for that destination rather than dropping the rule, because
dropping it reopens the whole LAN.

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
| 9 | out | DROP | — | — | **Dest:** `100.64.0.0/10` | Carrier-grade NAT, where a tailnet lives |
| 10 | out | DROP | — | — | **Dest:** `::/0` | IPv6, the whole family |

**Rule 9 is for a tailnet.** Tailscale numbers its hosts out of `100.64.0.0/10`,
which is none of the three RFC 1918 ranges, so without this rule a runner on
your tailnet reaches every machine you own anywhere — a wider network than the
one rules 5 to 7 were drawn around, not a narrower one. Add it whether or not
you run Tailscale today: it costs nothing on a VM with no overlay, and the day
someone installs one is not a day anyone revisits the firewall.

#### Rule 10, and why IPv6 is dropped whole

**IPv6 has no RFC 1918**, so there is no list of private ranges to mirror — the
family goes whole instead. Worth having even on a network that routes no IPv6,
because every Linux host answers on `fe80::` regardless. The argument is in
[the threat model](../docs/threat-model.md#the-lan-boundary-is-two-boundaries)
and again above `OUT DROP -dest ::/0` in
[firewall.fw.template](firewall.fw.template).

**`dejima-ci-firewall` blocks IPv6 too, one layer in, and it is not this.** Its
rules cover a confined job leaving its bridge. They are not in front of the VM's
own traffic, and on the privileged tier not in front of the jobs either, since
those run in the host's network namespace. Rule 10 covers root on the VM — the
privileged tier's ordinary case, not its worst one.

**Do it here, not with `disable_ipv6` in the guest**, which is a setting root on
a machine this page tells you to treat as already lost can put back.

**If the console rejects `::/0`**, enter four rules in rule 10's position
instead: `fe80::/10`, `fc00::/7`, `ff00::/8`, `2000::/3`.


#### Two more, if the VM gets its address by DHCP

Skip both if you pinned the address in the guest with `dejima-ci-static-ip`.
Add both if you did not, including when the address is reserved for you on the
router: reserved or not, the guest still speaks DHCP.

| # | Direction | Action | Protocol | Dest. port | Source / Dest | Why |
| --- | --- | --- | --- | --- | --- | --- |
| 1a | in | ACCEPT | udp | 68 | — | Let the lease reply back in |
| 4a | out | ACCEPT | udp | 67 | — | Let the lease request out |

Place `1a` with the other inbound rule and `4a` above the DROPs, as the
numbering suggests. Both name a port and no host, which makes them narrower
than an exception naming your DHCP server: they add no reachable host to the
list above.

**Both or neither.** Rule `4a` alone gets the request out and the VM still
never renews, because the reply arrives from the server's address to the VM's,
which is not the tuple the request created. Connection tracking is unlikely to
match that against `Input Policy: DROP`, so `1a` is what actually lets the
lease complete.

Do not count on rebinding to save you. At T2 the client stops unicasting and
broadcasts to `255.255.255.255`, which none of the DROPs match, so the request
does leave without rule `4a` — but the reply still needs `1a`. Half a working
path renews nothing.

This failure is slow and does not look like a firewall. Nothing breaks at
reboot or at first boot. The VM simply stops renewing, and somewhere up to a
full lease time later it drops off the network.

Rule `1a` lets anything on the segment send to the client port, which is a
spoofed-reply surface. It is close to free: DHCP on a LAN is trust-on-first-use
for every host on that segment whatever the firewall does, so permitting the
reply does not create that exposure. Not using DHCP is still narrower, and
`dejima-ci-static-ip` exists for it.

### Then apply it, per VM

A security group carries **rules and nothing else**. The policies are not part
of it, so each VM still needs its own:

**VM → Firewall → Options**

| | |
| --- | --- |
| Firewall | `Yes` |
| Input Policy | `DROP` |
| Output Policy | `ACCEPT` |

Inbound denies by default; outbound accepts by default and the LAN is denied
explicitly by the group. That asymmetry is deliberate: deny-by-default earns its
keep where the protected set is enumerable, which the LAN is and the internet is
not. The argument against inverting it is above `policy_out` in
[firewall.fw.template](firewall.fw.template).

Then **VM → Firewall → Add → Security Group**, and select
`dejima-ci-hardener`. That single entry is the whole rule set, in the order the
group defines, and it is the only firewall rule the VM needs.

Adding another runner later is that one step. The ordering below was got right
once, in one place, and cannot drift between hosts.

**Order matters within the group, and the console works against you here.**

Rules are evaluated top to bottom and the first match wins. Your forge and your
resolver are *inside* the ranges rules 5–8 drop, so if either pinhole ends up
below them it is dead and the runner cannot reach the forge or resolve anything.

**The console inserts each new rule at the TOP of the list, not the bottom.** So
entering rules 1 to 10 in the order they are written above leaves you with them
in reverse: the six DROPs on top, every pinhole beneath them, and a runner that
cannot reach its forge. Following the table without watching the list is enough
to produce exactly the failure this section is warning about.

Two ways through it. **Drag each rule to the bottom as you add it**, which keeps
the list matching the table at every step and is the easier one to check. Or
enter them in reverse, from 8 up to 1, and let the insertions stack into the
right order — quicker, and you are reading the table backwards while doing it,
which is its own way to get one wrong.

Either way, **read the finished list top to bottom and compare it against the
table** before you trust it. That is the only step here that catches the
mistake, because nothing else will: a dead pinhole looks exactly like a working
firewall until something tries to reach the forge.

Rules 2–4 are the entire remaining LAN exposure, and they are why "no LAN
access" is not literally true. Both destinations are pinned to one host and
one port.

Nothing follows rule 10. The public internet is reached by the default policy.

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

**Two passes.** The first reads configuration, the second tests behaviour, and
only the second is proof: a rule that is loaded and a rule that does what you
meant are different claims.

#### Pass one, on the node, with the VM running

Proxmox builds these chains around the tap device, so a stopped VM has none and
their absence would tell you nothing.

```sh
# what is actually loaded right now
sudo iptables -S | grep "tap<vmid>i0"

# the same, for the other address family. Rule 10 lands here and nowhere else
sudo ip6tables -S | grep "tap<vmid>i0"

# what Proxmox would generate from the current config
sudo pve-firewall compile | grep -B2 -A20 "tap<vmid>i0"
```

**Both tables, not just the first.** An IPv6 rule compiles into `ip6tables` and
is absent from `iptables -S`, which shows rule 10 missing whether it is there or
not.

**What you are looking for.** Chains named `tap<vmid>i0-IN` and `-OUT`, holding
your rules in the order you added them. The v4 `-OUT` chain has the three
pinhole ACCEPTs, then the five LAN DROPs, then whatever Proxmox appends for the
policy. The v6 `-OUT` chain has rule 10 and no pinholes, since every pinhole
names an IPv4 address.

| What you see | What it means |
| --- | --- |
| No `tap<vmid>i0` chains at all | The firewall is not applied to this VM. The NIC's Firewall checkbox, the VM's Firewall option, or the datacenter switch — check all three, in that order |
| Chains exist but hold none of your rules | The rules are on a different VM id, or were added at datacenter or node level rather than to this VM |
| A LAN DROP above a pinhole ACCEPT | The ordering trap. The runner will not reach the forge or resolve anything; drag the pinholes above the DROPs |
| Rules present and correct, DNS still failing | The address in rules 3–4 is not the VM's nameserver. The gateway is the usual wrong answer — see "Values that must agree" |
| v4 chain right, `ip6tables -S` empty | Rule 10 was not entered, or the console rejected `::/0` and the error was missed. Nothing about the v4 half will look wrong |

`pve-firewall status` reports the datacenter switch, not these rules.

#### Pass two, from inside the VM

Three must fail and two must succeed. That is what makes the set diagnostic
rather than reassuring.

Nothing needs installing: `bash` opens TCP connections itself, `getent` is part
of libc, and `ping` ships with Debian — which matters on a machine you have not
finished setting up yet.

```sh
try() { timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null \
        && echo "  CONNECTED  $1:$2" || echo "  blocked    $1:$2"; }

gw=$(ip -4 route show default | awk '{print $3; exit}')
dev=$(ip -4 route show default | awk '{for (i=1;i<NF;i++) if ($i=="dev") print $(i+1); exit}')

try "$gw" 443                  # must be blocked - your own first hop
try <forge-ip> 443             # must connect
try deb.debian.org 80          # must connect - the public internet
getent hosts deb.debian.org && echo "  resolved" || echo "  DNS FAILED"

# must find nobody but this VM - rule 10
sudo ping -6 -n -c 2 -W 1 -I "$dev" ff02::1
```

**The last one asks the whole LAN who is there, over IPv6.** Any reply from an
address that is not this VM's own means rule 10 is not in force, and that the
segment is reachable over a family none of the checks above it touch.

**This one is a by-hand check and stays one.** Everything else this repository
verifies, it verifies from inside a job, in `test/ci-runner.bats` — and a job is
the wrong vantage point for this question, because rule 10 is about the VM's own
reach and a confined job's traffic is stopped by `dejima-ci-firewall` before it
ever gets to the tap. The sister project checks the equivalent automatically
because it has an in-VM audit to hang it on; this one does not, so run it when
you build the group and after any change to it.

**Both targets are chosen so that naming them writes nothing down.** The
gateway is already in the routing table and `ff02::1` is the same on every
network there has ever been, so neither describes your topology to anyone
reading a machine this page tells you to treat as already lost. Both are also
guaranteed to answer when they are reachable, which an arbitrary host is not.

Read them together, because the pattern says which thing is wrong:

- **First one connects** → the firewall is not in force at all. Check the
  Network device's Firewall checkbox and the datacenter switch.
- **Second or third fails while the fourth works** → a pinhole is below the
  LAN DROPs. Check the rule order.
- **Only the last one finds neighbours** → the v4 half is right and rule 10 is
  missing. This is the failure that looks like success from every other angle,
  which is why it has its own probe.
- **Everything fails** → the VM has no working route or DNS at all, which is a
  networking problem rather than a firewall one. Note that this also makes the
  first probe's "blocked" meaningless: silence proves nothing when nothing is
  getting through, so re-read it only once the other three pass.

---

## The node side is done. Go back to the guest.

Everything above is what a hypervisor does and a guest cannot. The rest is
inside the VM: addressing, packages, the allowlist, the runners.

**Continue at [docs/building-a-runner.md §2](../docs/building-a-runner.md#2-addressing-leave-it-on-dhcp).**

That runbook sends you back here twice, to §4 below, once for each snapshot. It
says where each falls; this page says how to take them.

---

## 4. Snapshots and rollback

Three moments, and [docs/building-a-runner.md](../docs/building-a-runner.md)
says when each falls. The mechanics are the same for all of them: **shut the VM
down**, then **VM → Snapshots → Take Snapshot**, with *Include RAM*
**unticked**, then start it again.

| Name | When | What it is for |
| --- | --- | --- |
| `preflight` | after the OS is installed and its network verified, before anything is run on it | a known base to return to while iterating |
| `clean` | after the runner registers and the VM has been restarted once, before its first job | the state the rollback cadence returns to |

**Snapshot with it shut down, unless the guest agent is answering.** Proxmox
will snapshot a running VM, and without the agent what you get is
crash-consistent: the disk as it was at an instant, mid-writes included,
recovered by journal replay on the next boot. That is what pulling the plug
gives you, and it is a poor thing to restore unattended every week
indefinitely.

`qemu-guest-agent` removes the question — Proxmox asks it to freeze the guest's
filesystems for the duration, so a live snapshot is consistent.
`dejima-ci-bootstrap` installs it, and §2's Qemu Agent tick is what gives it a
channel to answer on. With both, snapshot the VM where it stands. With either
missing, shut it down first.

**And `clean` has an order it depends on**, which is easy to get wrong because
nothing complains at the time. It must be taken of a state that has already
booted successfully at least once *since the last change to the machine's
network configuration*. Rolling back is a cold boot - the disk is restored, the
VM is started - so every rollback re-applies whatever is in
`/etc/network/interfaces` and re-runs every unit. If that configuration is
wrong, the rollback is when it takes effect, and every rollback after it does
the same thing. Restart once and check the machine comes back before taking
`clean`, and the cadence cannot surprise you later.

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


## Why there is no script for this page

A script that runs `qm create` and writes into `/etc/pve/firewall/` is exactly
the kind of artifact people paste into a root shell without reading, and the
blast radius is the whole node — including every VM on it that has nothing to do
with CI. The steps above are short enough to follow and specific enough to
check, and you can see what you are doing while you do it.

The in-VM half **is** a script:
[`bin/dejima-ci-bootstrap`](../bin/dejima-ci-bootstrap). Running that blind
costs you a VM built to be lost, which is the difference.

One step here is not console work, because it cannot be: Proxmox schedules
backups but not rollbacks, so the cadence in §4 is a three-command cron entry,
printed in full and explained part by part.