# dejima-ci-hardener

Keeps a CI runner host's egress allowlist in sync with what the repositories
it serves have declared — read from the branch the operator controls.

## Do not install this next to dejima

This runs on a machine whose job is to execute untrusted code. dejima runs on
a machine you care about. Putting both on one host defeats the separation that
makes either of them worth anything, and this program holds a forge token and
rewrites a resolver's configuration — neither of which belongs within reach of
a sandbox session.

One host runs sandboxes. Another runs CI. This one belongs on the second.

## What problem this solves

A dejima session cannot reach outside its allowlist, but it can push a branch
and open a pull request — and CI then executes what it pushed, on a host, with
no firewall in front of it. There is no reliable way to require a human to
approve that first: the trigger, the workflow file and any in-workflow filter
all live in the tree the branch controls, and a stopped runner just means the
job lands in someone else's pool. See dejima's `docs/ci.md`.

So the runner's network is where the bound has to go. A dejima project already
carries a version-controlled statement of where it is allowed to reach:
`.dejima/allowed-domains`. This program turns that into the runner's DNS
allowlist — **read from `main` over the forge API, never from a checkout.**

A branch that can write its own allowlist does not have one. `main` got its
contents through a pull request someone merged. That is the whole design:
widening what CI can reach is a diff on `main` — reviewed, attributable,
revertible, and made in the same file and by the same act that widens what a
sandbox session may reach.

## What it is not

It does not configure the runner, the firewall or the Docker daemon. Those are
one-time setup, and dejima's `ci/` directory has worked examples of each along
with the order they have to be created in. This program owns one file: the
generated `server=` lines the resolver reads.

It also does not gate anything. Code still runs on every pull request. This
bounds where that code can reach, not whether it executes.

## Install

```sh
install -m 0755 bin/dejima-ci-allowlist /usr/local/bin/
install -d -m 0750 /etc/dejima-ci
install -m 0640 etc/config.example      /etc/dejima-ci/config
install -m 0640 etc/repos.example       /etc/dejima-ci/repos
install -m 0640 etc/base-domains.example /etc/dejima-ci/base-domains
install -m 0600 /dev/null               /etc/dejima-ci/forge-token   # then write the token

install -m 0644 systemd/dejima-ci-allowlist.* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now dejima-ci-allowlist.timer
```

Edit `/etc/dejima-ci/config` first — `forge_api` and `upstream` have no
defaults, and the program refuses to run without them.

The token needs read access and nothing else. This program only ever GETs one
file per repository, and a token that can do more is a token handed to a
machine that runs untrusted code.

## Use

```sh
dejima-ci-allowlist check    # what would change, without changing it; exit 1 if anything would
dejima-ci-allowlist render   # fetch, validate, install, reload if changed
dejima-ci-allowlist show     # what is installed right now
```

`check` is the one to reach for after merging a domain: it tells you whether
the runner has picked it up yet without waiting for the timer.

## How it fails

Every failure leaves the previous allowlist in place. That direction is
deliberate, and it is the thing to preserve in any change:

- A forge that does not answer, or answers with anything other than 200 or
  404, aborts the run. A 404 is a repository with no declaration, which is
  ordinary and skipped.
- A collection that comes out empty is refused rather than installed. An
  allowlist of nothing looks exactly like a working one until a job needs
  something.
- An entry that is not a plain domain name aborts the run rather than being
  skipped. A silently dropped entry reads as "that domain was never declared"
  and sends whoever debugs it to the wrong repository.
- A rendered file that fails `dnsmasq --test` is not installed. A resolver
  that will not start is a job network with no DNS at all, which fails every
  run rather than the one that caused it.
- An unchanged allowlist is not reinstalled, so the log stays useful for
  spotting when it actually changed.

## Tests

```sh
bats test/
```

Runs against a stubbed `curl` and `dnsmasq`. The properties worth keeping
covered are the ones above, plus that the config is parsed rather than sourced
and that an entry cannot smuggle a second resolver directive into the output.
