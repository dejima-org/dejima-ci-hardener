---
version: 1
title: Baseline, for a runner built before versions existed
layers: none
tiers: all
snapshot: none
---

# v1 — the baseline

Nothing to do. This version exists so that "no version recorded" has a name and
a place to be written down, rather than being a gap the tooling has to guess
about.

Every runner built before `VERSION` existed is a v1 runner. That is true
whichever tier it is, because until then there was one supported state — the tip
of `main` — and no way to be at any other.

## Establishing where you are

First, record the tier. It is not detected, for the reason in
[upgrades/README.md](README.md#tier-is-recorded-never-detected):

```sh
sudo dejima-ci-upgrade set-tier confined     # or privileged
```

Then `dejima-ci-upgrade status`. On a host with nothing else recorded it will
say so and stop. It does not assume v1, because a host that is genuinely at v1
and a host whose state file somebody deleted are the same thing from in here,
and picking the friendlier reading is how a check comes to be believed when it
does not know.

**On the confined tier**, `guest_version` is written by `install.sh`, from this
repository's `VERSION`. Re-running it from a current checkout is what records
it, and `install.sh` is idempotent by design — pressing Enter at every prompt
changes nothing. Remember that on a runner this is a rollback-sensitive change
like any other guest-side one; see
[docs/upgrading.md](../docs/upgrading.md#a-guest-side-upgrade-is-not-one-step).

**On the privileged tier** there is nothing to record. That tier installs
nothing in the guest, so `guest_version` stays unset and the tool reports `n/a`
rather than treating it as missing.

For the node half, read the notes from `0002` onward, do the console work each
describes, and record it with `dejima-ci-upgrade mark-node`. There is no
shortcut, because there is nothing in the guest that can read the hypervisor.
