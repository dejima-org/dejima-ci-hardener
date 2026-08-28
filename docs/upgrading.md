# Upgrading a runner that already exists

A runner VM is pinned to the moment it was built. Half its controls were entered
by hand in a hypervisor console, and the other half were installed from a
checkout that has since moved on.

And unlike the sister project, it has **a second way of going backwards**: the
scheduled rollback rebuilds it from a snapshot. That is this project's
distinctive control and the reason a runner can be treated so casually, and it
is also the reason an upgrade here is not simply "apply the change".

## Why this project has one and dejima does not

dejima's containers are short-lived and only the tip of `main` is supported. A
gap opens, `git pull` closes it, and the next container starts from the closed
state. Nothing is pinned, so nothing drifts.

| | dejima | a runner VM |
| --- | --- | --- |
| Lifetime | one session | months |
| Where the controls live | in the image, rebuilt each run | half in the guest, half typed into a console |
| How a gap closes | `git pull` | a person, deliberately, on two machines |
| Can it move backwards? | no | **yes, on a schedule** |

## A guest-side upgrade is not one step

This is the whole of it, and it is the step people skip:

> The scheduled rollback rebuilds this VM from a snapshot. A guest-side change
> applied to the running machine and never baked into that snapshot is undone at
> the next rebuild, on a timer, with nothing to see.

So a guest-layer upgrade is a sequence. `dejima-ci-upgrade status` prints it
whenever one is outstanding, rather than leaving it to be remembered.

**1. Do the node work first.** Hypervisor rules live outside the VM and no
rollback touches them. Doing them first also means that if you are interrupted,
you are interrupted in the safe order: the boundary is tightened and the guest
is merely stale.

**2. Stop the runner and let jobs drain.**

```sh
cd ~/dejima-ci && docker compose stop
```

**3. Roll back to the clean snapshot first.**

The counter-intuitive one. Upgrade from a known-clean base rather than from
whatever the last few weeks of jobs left behind — otherwise you are about to
promote that residue into your new rollback target and keep it forever.

**4. Apply the guest change**, from a current checkout:

```sh
git -C ~/dejima-ci-hardener pull
cd ~/dejima-ci-hardener
sudo ./install.sh
```

`install.sh` is idempotent; Enter at every prompt keeps what you have. It writes
`guest_version` into `/etc/dejima-ci/state` from the checkout's `VERSION`.

**5. Verify**, per the upgrade note. At minimum, that the runner comes back and
takes a job.

**6. Take a NEW snapshot.**

**7. Repoint the rollback job at the new snapshot, and confirm it.** Skip this
and step 6 was decoration: the job still names the old snapshot and will restore
it on schedule, discarding everything above. `proxmox/README.md` §4 has the job
and the check.

Then delete the old snapshot, or name it so its date is unmissable. An old
snapshot is a bootable copy of whatever the upgrade fixed, wired to a timer.

### The one that fails safe

The state file lives in `/etc/dejima-ci`, inside the guest, so it is **inside
the snapshot** and rolls back with everything else.

That is correct rather than unfortunate. Forget step 6 and the version marker
reverts alongside the change it was recording, so `dejima-ci-upgrade status`
goes back to reporting the upgrade as outstanding. The system fails towards
saying there is work to do, which is the direction to fail in.

## The two version numbers

`/etc/dejima-ci/state`:

```
tier=confined
guest_version=2
node_version=2
node_asserted=2026-08-25
node_verified=yes
```

**`guest_version`** is written by `install.sh`. The **privileged tier has no
`install.sh`** and no guest-side install at all — that is the grant the tier
exists for — so there it stays unset, and the tool reports `n/a` rather than
treating it as a gap.

**`node_version`** is written by `dejima-ci-upgrade mark-node`, by you, saying
you did the console work.

**Both are guest state, so a rollback takes both.** That is worth stating
plainly because it makes recording anything on a runner a guest-side change
with the same seven steps behind it. Two consequences follow, and neither is a
bug:

- Recording a node-only upgrade is **optional**. The console work is on the
  hypervisor and is in force whether or not a file in the guest says so.
- After a rollback, `status` will list a recorded upgrade as outstanding again.
  It does not simply believe that: where the upgrade declares a `verify-node`
  command it runs the check first, and where the check passes it says *NOT
  RECORDED, but its check passes* rather than *console work outstanding*. Nothing in the guest can read the hypervisor's rules,
which is exactly what makes those rules the boundary, so it is an assertion and
the tool treats it as one.

| | Means |
| --- | --- |
| `node` behind `guest` | Console work outstanding. The ordinary case after a pull. |
| `guest` behind `node` | On a runner, usually a guest upgrade that was applied and never re-snapshotted, since undone by the rollback. |

## Tier is recorded, never detected

```sh
sudo dejima-ci-upgrade set-tier confined      # or privileged
```

An absent `/etc/dejima-ci/config` identifies a privileged host correctly, and
also identifies a confined host whose `install.sh` has not run yet. Guessing
wrong selects a different set of upgrades — the same failure
`test/ci-runner.bats` takes `DEJIMA_CI_TIER` rather than sniffing for, on the
same grounds.

## Where the assertion gets checked

An upgrade may declare a `verify-node` command that passes only if the console
work is in force. For v2 that is `dejima-ci-upgrade check-lan`, which asks
`ff02::1` who is on the link and counts the replies that are not this VM's own.

- `mark-node` **runs it first and refuses to record a claim the machine
  contradicts.** `--force` overrides and records the result as unverified, so
  `status` keeps saying so.
- **A check that cannot tell is not a check that failed.** The contract is exit
  `0` for in force, `2` for could-not-determine, anything else for not in
  force. `check-lan` exits `2` with no `ping` to probe with, and `mark-node`
  records the assertion as unverified rather than refusing it — telling an
  operator their console work is missing on the strength of a check that never
  ran would be wrong in the alarming direction.
- **The command is looked up on `$PATH` first, then beside this program.** The
  fallback is what makes the documented workflow work: the notes say to run
  from a checkout on a box where nothing is installed, and without it the tool
  could not find itself.
- `status` re-runs the checks for everything already recorded. An assertion that
  was true in June and is false now is a rule somebody removed.

`check-lan` is a narrow test of one node rule, not an audit. This repository has
nothing else that runs inside the VM: `test/ci-runner.bats` runs inside a *job*,
which is the wrong vantage point, because a confined job's traffic is stopped by
`dejima-ci-firewall` long before it reaches the tap. The sister project has an
in-VM audit and checks more this way. That asymmetry is real and is not closed
here.

## Adding an upgrade, if you are changing this repository

1. Bump `VERSION`.
2. Write `upgrades/000N-slug.md` with the header
   [documented here](../upgrades/README.md#the-header).
3. Set `layers:` honestly. Anything including `guest` is rollback-sensitive by
   construction and the tool will print the seven steps.
4. Give it a `verify-node:` where the node-side change has an observable
   consequence from inside the guest.
5. Write it for a person standing at a console who has not read the diff.

**Write one for every version, including versions that need nothing.** A missing
file and a file saying "nothing to do" are the same thing to a reader who has to
go looking.
