---
version: 3
title: Each runner pool gets the allowlist it could actually run
layers: guest
tiers: confined
snapshot: required
---

# v3: each runner pool gets the allowlist it could actually run

Confined tier only. **This one has a migration**: the render refuses until the
pools on this host are declared. Do the whole sequence in one sitting.

## Why

Every job resolved against one list and was filtered by one ipset, so a name any
trusted repository declared was reachable from every repository's jobs. One
project's declaration widened all of them.

The set is the part that matters. It holds addresses with no memory of which
name put them there, so scoping the resolver alone would have changed almost
nothing: a job that could not resolve another project's name could still connect
to the address that name resolved to, and declarations are public.

## What replaces it

**A set per runner pool, holding the union of every declaration that pool could
be made to run.** That is the only union that is safe. A pool takes jobs from
the repositories it is registered for, so a hostile branch in one of them can
already put a job on that pool; its names being in that pool's set gives away
nothing the branch did not already have. What the set leaves out is every
repository the pool cannot run at all.

The scoping you get is the scoping you registered:

| A pool registered to | Its set holds |
| --- | --- |
| one repository | that repository's declaration |
| an owner, so an organisation or user pool | the union across that owner's repositories |

**Registering a pool to one repository is how it gets a small set.** It is the
recommendation, not the mechanism. An owner-scoped pool is not a
misconfiguration: it is a pool that genuinely can run any of those
repositories' jobs, holding exactly what that implies.

**Labels are not part of this.** A branch chooses its own `runs-on`, so a label
is a request rather than a boundary. What a runner may take is decided by what
it is registered to, which a branch cannot change. Pools can share labels.

## 1. Install

```sh
cd ~/dejima-ci-hardener
git pull
sudo ./install.sh
```

**Say no to the runner question.** On a host that already has pools it now
defaults to no, and lists what you have with each pool's count, label and
network, so there is nothing to go and look up. Your runners are untouched
either way.

The timer's next render will refuse, naming repositories no declared pool can
run. Expected here, and safe: nothing is installed on a failure, so the
allowlist already in force stays in force while you work through the rest.

**Re-snapshot before this tier's next scheduled rollback.** These are guest
changes on a runner rebuilt from a snapshot, so one taken before this restores a
host without them, and the render starts refusing again with nothing to explain
it.

## 2. Declare the pools you have

One line per pool, named by what it is **registered** to. The installer just
listed your projects; the forge's **Actions, Runners** pages say which scope
each was registered at, since a runner appears under the repository or the owner
it belongs to.

```sh
sudo dejima-ci-allowlist pools add dejima          # an org-scoped pool
sudo dejima-ci-allowlist pools add branderson      # a user-scoped pool
sudo dejima-ci-allowlist pools add acme/widget     # one registered to a repo
```

Each assigns an id, **creates that pool's network**, and prints what is left.

## 3. Render and apply

```sh
sudo dejima-ci-allowlist render      # should stop refusing
sudo dejima-ci-firewall
```

If it still refuses it names what is missing, and nothing has been installed in
the meantime.

## 4. Move each pool onto its network

**This is the step that decides whether any of it took effect.** A pool still on
the shared network reaches the base names only.

```sh
sudo dejima-ci-runners --role confined --network dejima-ci-1 \
     --dir ~/runners/<the project the installer listed>
```

The generator reads the project already in that directory and offers its values
back, so entering through its questions changes the network and keeps your count
and label. Labels do not need to change: the registration decides which jobs a
runner may take, and a pool registered to one repository cannot take another's
however a branch writes its `runs-on`.

## Checking it worked

```sh
sudo dejima-ci-allowlist pools list
sudo iptables -S DEJIMA-CI-FWD | grep dejima-ci1
```

The rule for that bridge should name `ci-allow-1` and `ci-allow-base`, and
nothing else.

## What this does not do

**Every job can still resolve every allowlisted name.** One dnsmasq has one
view, and a per-pool view would mean a resolver per pool. What a job can reach
is the set its bridge matches, so resolving a name it may not connect to gets it
an address the firewall drops. The leak is names, which are public in the
repositories that declared them.

It does not scope the privileged tier, which has no allowlist and no job network
to scope: its jobs are in the host's network namespace by design.
