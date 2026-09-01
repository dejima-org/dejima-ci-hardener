---
version: 3
title: A project can be given a firewall set of its own
layers: guest
tiers: confined
snapshot: required
---

# v3: every project gets a firewall set of its own

Confined tier only. **This one has a migration**: after it, a repository that
declares names needs a set of its own, and the render refuses until each of them
has one. Do the whole sequence in one sitting.

## Why

Every job on this host resolved against one list and was filtered by one ipset,
so a name any trusted repository declared was reachable from every repository's
jobs. One project's declaration widened all of them.

The set is the part that matters. It holds addresses with no memory of which
name put them there, so giving each project its own resolver would have changed
almost nothing: a project that could not resolve another's name could still
connect to the address that name resolved to, and declarations are public in the
repositories they come from.

## What is new

`dejima-ci-allowlist` writes an `ipset=` line per name, listing the sets of the
projects that declared it. dnsmasq accepts several per name, so one resolver
fills each declaring project's set and no others.

`dejima-ci-firewall` matches each bridge against its own project's set and a
base set every project shares.

There is no shared fallback. A repository that declares names and has no set is
refused rather than put somewhere every other project can reach: a set everyone
shares is what this exists to end, and falling back to one would mean arriving
there by doing nothing rather than by choosing it.

A repository that declares nothing needs no assignment, having no names to
scope. It needs one the day it declares something, and the refusal is what tells
whoever added that declaration.

## 1. Before you install: what will need a set

```sh
sudo dejima-ci-allowlist render
```

Read the collection lines. Every repository reporting names declared is one that
needs a set; the ones reporting no declaration do not. Write that list down.

## 2. Install

```sh
cd ~/dejima-ci-hardener
git pull
sudo ./install.sh
```

The timer's next render will refuse, naming the repositories that need a set.
That is expected here, and it is safe: nothing is installed on a failure, so the
allowlist already in force stays in force while you work through the rest.

**Re-snapshot before this tier's next scheduled rollback.** These are guest
changes on a runner rebuilt from a snapshot, so one taken before this restores a
host without them: the tools go back, the projects file goes back, and the
render starts refusing again with nothing to explain it.

## 3. Assign each declaring repository

One at a time:

```sh
sudo dejima-ci-allowlist projects assign owner/repo
```

It prints the id and the commands that make it real, including the network. Do
those before moving on: an assignment with no network is a bridge the firewall
has no rules for.

## 4. Render and apply

Once every declaring repository has a set:

```sh
sudo dejima-ci-allowlist render      # should stop refusing
sudo dejima-ci-firewall
```

If it still refuses, it names what is missing. Nothing has been installed in the
meantime.

## 5. Move each project's runners onto its own network

**This is the step that decides whether any of it took effect.** A runner takes
whatever jobs it is offered, so a pool on the shared network puts that project's
jobs back among everyone else's names however carefully the sets were assigned.

Register a pool to that repository alone, from the forge's
**Settings, Actions, Runners** page on the repository rather than the
organisation, and point it at the new network:

```sh
sudo dejima-ci-runners --role confined --network dejima-ci-1 \
     --dir ~/runners/owner-repo
```

Then take that repository out of any organisation-wide pool's reach, or its jobs
will keep landing wherever they did before.

Until a project's pool has moved, its jobs run on the shared network and reach
the base names only, because the shared bridge now matches the base set and
nothing else. That is a job that fails rather than a job that reaches too far,
which is the direction to be wrong in, but it is why steps 4 and 5 belong in one
sitting.

## Checking it worked

```sh
sudo dejima-ci-allowlist projects list
sudo ipset list ci-allow-1 | head
sudo iptables -S DEJIMA-CI-FWD | grep dejima-ci1
```

The rule for that bridge should name `ci-allow-1` and `ci-allow-base`, and
nothing else. If it names `ci-allow`, the bridge has no entry in the projects
file or the firewall has not been re-run.

## What this does not do

**Every job can still resolve every allowlisted name.** One dnsmasq has one
view, and giving each project its own would mean a resolver instance per
project. What a job can reach is the set its bridge matches, so resolving a name
it may not connect to gets it an address the firewall drops. The leak is names,
which are already public in the repositories that declared them.

It does not scope the privileged tier, which has no allowlist and no job network
to scope: its jobs are in the host's network namespace by design.
