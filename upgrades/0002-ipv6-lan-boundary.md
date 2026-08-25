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

The node firewall's outbound DROPs named IPv4 ranges only, so the boundary
`proxmox/firewall.fw.template` calls "THIS IS THE BOUNDARY" did not apply to
IPv6 at all. Every Linux host brings up an `fe80::` address on every interface
whether or not anything routes v6, and a daemon bound to `::` answers on it — so
the machine beside your runner was reachable across the segment with all four
DROPs in force, on a network with no IPv6 in it.

**`dejima-ci-firewall` was already blocking IPv6 and it is not the same thing.**
Those rules are bound to the job bridge with `-i "$b"`. They cover a confined
job reaching off its bridge. They are not in front of the VM's own traffic, and
on the **privileged tier they are not in front of the jobs either**, because
those run in the host's network namespace where bridge rules do not apply. On
that tier root on the VM is the ordinary case rather than the worst one, and
these two rules are the only thing covering it.

The full argument is in
[the threat model](../docs/threat-model.md#the-lan-boundary-is-two-boundaries).
The short version: IPv6 has no RFC 1918, so the family is dropped whole rather
than enumerated.

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

You are appending. Nothing else in the group changes, and a security group edit
applies to every VM referencing it immediately — so if you run a privileged and
a confined runner off the same group, this is one edit for both.

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

In the guest:

```sh
sudo dejima-ci-upgrade set-tier confined     # or privileged, once, if not yet set
sudo dejima-ci-upgrade mark-node 2
```

`mark-node` runs `dejima-ci-upgrade check-lan` first — which asks `ff02::1` who
is on the link and counts the replies that are not this VM's own — and refuses
to record the assertion if anything answers. So what gets written down has been
corroborated rather than claimed.

`check-lan` needs `ping`, from `iputils-ping`. Without it the check reports
`UNKNOWN`, which is not a pass, and `mark-node` records the assertion as
unverified so `status` keeps saying so.

## What this does not change

No guest-side change, so **no new snapshot and no rollback sequence**. Your
existing snapshot is still a correct rollback target: it contains no v1-specific
guest state that this upgrade invalidates, and the node rules it will boot into
are the new ones either way.

Internet egress over IPv4 is untouched. Still unbounded, still deliberate, and
the reason is in `proxmox/firewall.fw.template` above `policy_out`.
