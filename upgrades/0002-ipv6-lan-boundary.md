---
version: 2
title: The LAN boundary gains IPv6 and the CGNAT range
layers: node
tiers: all
snapshot: none
verify-node: dejima-ci-upgrade check-lan
---

# v2 — the LAN boundary gains IPv6 and the CGNAT range

**Two rules in the Proxmox console, and nothing else.** No guest change, no
rollback dance, no new snapshot. Ten minutes.

This is the cheap kind of upgrade and it is worth saying why, because the next
one may not be: everything here lives on the hypervisor, outside the VM, where
no rollback reaches it. Guest-side upgrades on a runner are a seven-step
sequence. This is not one.

Applies to **both tiers**. The privileged tier needs it most — see below — but
the rules are identical and the security group is shared.

## Why

Until you do this, **your runner reaches its neighbours over IPv6** — on a
network with no IPv6 in it, because every Linux host answers on `fe80::`
regardless. All four v4 DROPs are in force and irrelevant.

**`dejima-ci-firewall` blocks IPv6 too, and it is not the same thing.** Its
rules are bound to the job bridge, so they cover a confined job leaving that
bridge. They are not in front of the VM's own traffic, and on the **privileged
tier not in front of the jobs either**, since those run in the host's network
namespace. There, root on the VM is the ordinary case rather than the worst one,
and these two rules are the only thing covering it.

Why the family is dropped whole rather than enumerated:
[the threat model](../docs/threat-model.md#the-lan-boundary-is-two-boundaries).

## 1. Node — two rules in the Proxmox console

**Datacenter → Firewall → Security Group → `dejima-ci-hardener`.**

Add these two. They are rules 9 and 10 of
[the table in the runbook](../proxmox/README.md#build-the-group-once):

| # | Direction | Action | Protocol | Dest. port | Source / Dest |
| --- | --- | --- | --- | --- | --- |
| 9 | out | DROP | — | — | **Dest:** `100.64.0.0/10` |
| 10 | out | DROP | — | — | **Dest:** `::/0` |

**Both go at the bottom, below every existing rule.** The console inserts each
new rule at the *top*, so a rule left where it lands sits above your forge and
resolver pinholes. These two are DROPs; put them above the pinholes and the
runner stops reaching its forge and stops resolving. Drag each one down as you
add it.

You are appending. Nothing else in the group changes.

**Nothing to restart.** A security group edit applies to every VM referencing it
immediately, so if you run a privileged and a confined runner off the same
group, this is one edit for both. If you built the rules per-VM rather than as a
group, you have this to do on each VM, and building the group is worth doing
while you are here.

**If the console rejects `::/0`**, enter four rules in rule 10's position
instead — `fe80::/10`, `fc00::/7`, `ff00::/8`, `2000::/3`.

### One thing to weigh on a confined host

Rule 9 drops `100.64.0.0/10`, and rule 10 drops IPv6 egress to the internet as
well as to your LAN, because the family goes whole.

For a confined job neither changes anything: `dejima-ci-firewall` already
rejects IPv6 on the job bridge, and off-list v4 destinations were already
refused by the allowlist. It could matter to a **privileged** job that fetches
from a v6-only host, or to any job whose repository declares an internal name
that resolves into carrier-grade NAT space — a tailnet address, typically.

If you hit either, the fix is a pinhole for that destination above the DROPs,
not dropping the rule. Dropping it reopens the whole LAN to get one host back.

### Check the node half landed

On the node:

```sh
sudo ip6tables -S | grep "tap<vmid>i0"
```

An IPv6 rule is compiled into `ip6tables` and is **absent from `iptables -S`**,
so the v4 table shows rule 10 missing whether it is there or not. Checking the
wrong table is the most likely way to conclude this worked when it did not.

## 2. Record it

**Run the tool from a checkout, not from `$PATH`.** `dejima-ci-upgrade` arrives
*with* v2, and v2 has no guest-side step — so on the runner you are upgrading it
is not installed yet, and will not be by anything on this page.

In the guest:

```sh
git clone <this repo> ~/dejima-ci-hardener      # or pull, if you have it
cd ~/dejima-ci-hardener

sudo ./bin/dejima-ci-upgrade set-tier confined  # or privileged, once per host
sudo ./bin/dejima-ci-upgrade mark-node 2
```

`mark-node` runs `check-lan` first — which asks `ff02::1` who is on the link and
counts the replies that are not this VM's own — and refuses to record the
assertion if anything answers. So what gets written down has been corroborated
rather than claimed.

Running from a checkout is the better way on either tier anyway, and stays true
after this upgrade: an installed copy knows only the versions that existed when
it was installed.

### If `check-lan` reports UNKNOWN

It needs `ping`, from `iputils-ping`. Without it there is no probe and the check
says `UNKNOWN`, which is not a pass — `mark-node` records the assertion as
unverified and `status` keeps saying so.

Installing it is a **guest-side change on a machine a rollback rebuilds**, so it
does not survive on its own. Two honest options, and no third:

- `sudo apt-get install -y iputils-ping`, verify, and accept that the next
  rollback removes it again. The node rule is unaffected either way — this is
  only about being able to check it — so the cost is that a later `status`
  reports `UNKNOWN` rather than `in force`.
- Leave it, and verify from the node instead with `ip6tables -S` as in §1. The
  assertion is then recorded unverified, which is what it actually is.

Baking `iputils-ping` into the snapshot is reasonable, but it is a guest-side
change and takes the seven steps in
[docs/upgrading.md](../docs/upgrading.md#a-guest-side-upgrade-is-not-one-step).
Do not do it casually as part of this upgrade.

### Do not run `install.sh` just to get the tool onto the box

Tempting on the confined tier, and it would work — `install.sh` installs
`dejima-ci-upgrade` and the upgrade notes. But **that is a guest-side change**,
so the next rollback reverts it along with the `guest_version` it wrote, and you
are back where you started with no sign anything happened.

If you want the tool installed, do it as its own deliberate change through the
seven steps. It is not needed for v2, and the checkout above is enough.

## 3. Confirm

```sh
sudo ./bin/dejima-ci-upgrade status
```

Both halves at v2, and the node check re-run to confirm the console work is
still in force. This is also what to run in six months: `status` re-checks
everything already recorded, so a rule somebody removes later shows up here
rather than in an incident.

## What this does not change

No guest-side change, so **no new snapshot and no rollback sequence**. Your
existing snapshot is still a correct rollback target: it contains no v1-specific
guest state that this upgrade invalidates, and the node rules it will boot into
are the new ones either way.

Internet egress over IPv4 is untouched. Still unbounded, still deliberate, and
the reason is in `proxmox/firewall.fw.template` above `policy_out`.
