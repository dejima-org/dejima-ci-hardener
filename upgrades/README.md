# upgrades

One file per version. `000N-slug.md` is what an operator has to do to reach
version `N` from version `N-1`, and there is one for every version including the
ones that need nothing — an absent file would be indistinguishable from a file
nobody wrote.

`dejima-ci-upgrade` reads these. So does a person, and the file is written for
the person; the header exists so the tool can sort, filter and check without the
prose having to be machine-readable.

## Why this exists at all

dejima has no equivalent and does not need one. Its containers are short-lived,
only the tip of `main` is supported, and `git pull` closes any gap that opens.

A runner VM is pinned to the moment it was built, and its hypervisor rules were
entered by hand in a console no pull can reach. It also has **a second way of
going backwards that the sister project does not have**: the scheduled rollback
rebuilds it from a snapshot, so a guest-side change that was never baked into
that snapshot is undone on a timer, with nothing to see.

That is the whole reason a guest-layer upgrade here is a sequence rather than a
command.

## The header

```
---
version: 2
title: The LAN boundary gains IPv6 and the CGNAT range
layers: node
tiers: all
snapshot: none
verify-node: dejima-ci-upgrade check-lan
---
```

| Key | Means |
| --- | --- |
| `version` | The version this upgrade arrives at. Must match the filename. |
| `title` | One line, shown in `status`. |
| `layers` | `node`, `guest`, both, or `none`. Which halves need work. |
| `tiers` | `all`, `confined`, or `privileged`. |
| `snapshot` | `required` or `none`. On a runner, see below — it does not mean "take a backup". |
| `verify-node` | Optional. A command that passes only if the node-side work is in force. |

## `snapshot: required` means the rollback target changes

On a devbox, a snapshot is a thing you might restore later. On a runner it is
the thing the machine is **rebuilt from, on a schedule**. So `required` here does
not mean "make a backup first". It means:

> the change is lost at the next rollback unless the snapshot the rollback job
> targets is replaced.

Any upgrade whose `layers` includes `guest` is in this position by construction.
The node half never is: hypervisor rules live outside the VM and no rollback
touches them.

The sequence is in [docs/upgrading.md](../docs/upgrading.md#a-guest-side-upgrade-is-not-one-step),
and `dejima-ci-upgrade status` prints it whenever a guest-layer upgrade is
outstanding, because it is the step people skip.

## Two version numbers, not one

`/etc/dejima-ci/state`:

**`guest_version`** is written by `install.sh` when it runs. The privileged tier
has no `install.sh` and no guest-side install at all — that is the grant the tier
exists for — so there it stays unset and means it, rather than reading as a gap.

**`node_version`** is written by `dejima-ci-upgrade mark-node`, by an operator
saying they did the console work. Nothing in the guest can read the hypervisor's
rules, which is exactly what makes those rules the boundary, so this is an
assertion and the tool treats it as one. Where an upgrade names a `verify-node`
command the tool runs it, and it is allowed to contradict the assertion.

**The state file is inside the snapshot**, so it rolls back with the guest. That
is correct rather than unfortunate: forget step 6 and the version marker reverts
alongside the change it was recording, so the tool goes back to reporting the
upgrade as outstanding. It fails towards saying there is work to do.

## Tier is recorded, never detected

An absent `/etc/dejima-ci/config` identifies a privileged host correctly, and
also identifies a confined host whose `install.sh` has not run yet. Guessing
wrong selects a different set of upgrades, which is the same failure
`test/ci-runner.bats` takes `DEJIMA_CI_TIER` rather than sniffing for.

```sh
dejima-ci-upgrade set-tier confined
```

## Where the tool comes from on each tier

`install.sh` installs `dejima-ci-upgrade` and these notes, and `install.sh` runs
on the confined tier only. A privileged host installs nothing in the guest, so
run the tool from a checkout there.

That is the better way on either tier. An installed copy shipped with the notes
that existed when it ran, so it cannot tell you about a version released since —
and it says so, rather than reporting "up to date" about versions it has never
heard of.
