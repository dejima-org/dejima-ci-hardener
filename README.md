<!-- Fixed, not preference-aware, and that is the decision rather than an
     oversight. `prefers-color-scheme` reports the browser's setting, never the
     site's, and this is read on a forge that renders dark whichever way the
     browser is set - so anything conditional shows dark ink on a dark page to
     a reader whose browser prefers light, and does it silently.
     The suffix names the mode a file is FOR, not the colour of its ink:
     -darkmode is the pale wordmark that belongs on a dark page. A mirror on a
     light-themed host swaps the filename below for dejima-wordmark-lightmode.png,
     which is committed alongside for exactly that. One line, on the mirror,
     where someone can see whether it worked. -->
<img src="assets/dejima-wordmark-darkmode.png" alt="dejima" height="72">

# Continuous Integration Hardener

Hardens a continuous integration runner host that executes agent-authored code
on every pull request, and gives its jobs as little as possible to execute it
with.

**This is the only thing you clone onto a CI box.** It is self-contained -
there is no step that copies files out of a dejima checkout, and dejima itself
never needs to be present here.

There are two kinds of runner host. Both are built by the same runbook and the
same command, differing in one flag; what differs is what a job on them is
granted, and so where the boundary containing it sits. Pick the tier first -
only one of the two halves below applies.

For *why* any of this is necessary - what a CI run adds over a sandbox, and
why no approval gate is offered - see [dejima's `docs/ci.md`](https://gitbox.branderson.io/dejima/dejima/src/branch/main/docs/ci.md). You do
not need it to follow this.

## Do not install this next to dejima

This runs on a machine whose job is to execute untrusted code. dejima runs on
a machine you care about. Putting both on one host defeats the separation that
makes either worth anything, and this program holds a forge token and rewrites
a resolver's configuration - neither of which belongs within reach of a
sandbox session.

## Two tiers, and you must pick one

The difference is not how much a job is granted. It is **where the security
boundary sits**, and therefore what you have to build to have one at all.

| | **confined** | **privileged** |
| --- | --- | --- |
| Built by | `--role confined` | `--role privileged` |
| Docker socket in job containers | no | **yes** |
| Job networking | its own bridge | the host's namespace |
| Egress allowlist in front of jobs | yes, from each repo's `main` | **none, by design** |
| A compromised job reaches | only the declared domains | the whole public internet |
| The boundary is | in the host | on the hypervisor |
| Treat this host as | expected to hold | already lost |
| Runs `install.sh` | yes | no, deliberately |
| For | tests, lint, anything needing no daemon | image builds, tests needing a real daemon or host networking |

**Confined** is where everything belongs that can go there. Its jobs get no
Docker socket, run on a bridge this tool creates, and reach only the domains
the served repositories declare in `.dejima/allowed-domains` on their `main`.
`dejima-ci-bootstrap --role confined` builds all of it.

**Privileged** exists for the jobs that cannot work otherwise: building a
Docker image, or dejima's own runtime tests, which assert things about a real
daemon and a real host network. Both grants are root-equivalent on the host,
and neither can be reduced without breaking the job they exist for. That tier
needs a machine built to be lost, not a machine you own.

### Why confine anything, if the hypervisor holds either way

Worth answering directly, because the objection is sound as far as it goes. The
node firewall's guarantee is identical on both tiers — *reaches the internet,
not your network* — and it is enforced somewhere neither tier can touch. If
your LAN were the whole of the threat, the confined tier would be ceremony.

What that guarantee leaves open is the internet, and the internet is where the
damage in this threat model actually happens. A prompt-injected session, or a
dependency that ships something unwanted, has no need of your LAN. It needs
somewhere to send a checkout, a token or a set of CI secrets, and somewhere to
fetch its next instruction from. Every one of those is a public address, and
the node firewall permits all of them by design.

The confined tier closes that, in two places at once:

- **Its jobs are handed no Docker socket**, so the ordinary compromise stays
  inside a job container instead of becoming root on the host.
- **Their egress is deny-by-default.** An unlisted name does not resolve, and
  an unlisted address is unreachable even when named as a literal IP — the
  resolver and the packet filter are separate controls, and a job has to get
  past both. Reaching anywhere off the list at all means escaping the container
  first.

The list is the part that carries the most weight, and it is not a file on the
host. It is `.dejima/allowed-domains` on each served repository's `main`, so
widening it is a reviewed, attributable diff on a branch a pull request cannot
write. **A branch cannot grant itself a destination**, which is the property
the whole tool exists for.

So the tiers bound different things, and neither is a weaker version of the
other. The privileged tier bounds the catastrophic case — an attacker on your
network — and accepts the ordinary one, since a job there reaches the whole
internet by design. That is why that machine is built to be lost and rolled
back on a schedule. The confined tier bounds the ordinary case, which is the
one that actually happens, and which a hypervisor firewall cannot see: it is
all outbound traffic to legitimate public addresses.

Put the other way round: the node firewall decides *whose* network a job can
reach. Only the confined tier decides *what it can say and to whom*.

### The privileged tier has no egress allowlist, on purpose

This is the split's most important consequence and the easiest to read as an
omission, so plainly: it is not one.

The confined tier's allowlist works because its jobs cannot reach it. The
rules sit on a bridge their traffic has to cross, in a network namespace they
are not in, enforced by a kernel they hold no privileged access to.

A privileged job has all three. It holds the Docker socket, which is
root-equivalent on that host, and it runs in the host's own network namespace.
Any filter installed there is one it can flush in a single command. Installing
it anyway would cost an evening and leave a host that *looks* like it has an
egress allowlist, which is worse than one that plainly does not: the next
person to reason about that machine reasons from the label.

So `dejima-ci-bootstrap --role privileged` deliberately stops short of running
`install.sh`, and the boundary moves outward - to the hypervisor's firewall,
applied to the VM's tap device, where the guest cannot reach it.

The guarantee that survives is narrower and honest, and it is the one worth
making: **an attacker who owns that VM reaches the internet, and not your
network.**

---

# Build one

Two pages, in this order. Neither repeats the other.

1. **Your hypervisor.** On Proxmox:
   [proxmox/README.md](proxmox/README.md) — the VM, the firewall applied to
   it, and its snapshots. On anything else, the equivalent is a VM that
   reaches the internet and, on your LAN, only your forge and a resolver.
2. **The host inside it.**
   [docs/building-a-runner.md](docs/building-a-runner.md) — the Debian
   install, one bootstrap command, and the runners. The same on any
   hypervisor, and the same for both tiers bar one flag.

The whole of the tier decision is that flag, which the second page runs for
you at the point it belongs:

```sh
--role confined      --role privileged
```

On `confined` the bootstrap additionally runs `install.sh`, which builds the job network,
its allowlisting resolver and the egress rules. On `privileged` it stops short
of that, for [the reason above](#the-privileged-tier-has-no-egress-allowlist-on-purpose).

One thing that is not in either page, because no program can do it: **do not
put a privileged runner on a machine you would mind losing.** Its jobs are
handed the Docker socket, so the working assumption has to be that a
compromised job gets root on that host, and handing an existing machine to that
assumption is not a decision many people would make deliberately.

---

# Both tiers

## Register scope is the boundary; the label is not

A dedicated label routes honest jobs to the runner you prepared. It stops
nothing else, because `runs-on:` lives in the workflow file and the workflow
file lives in the branch. A branch can name any label it likes, so a session
that changes `runs-on: dejima-ci` to `runs-on: ubuntu-latest` and opens a pull
request has stepped outside everything this tool installs - provided some
runner answering that label will take the job.

Whether one will depends on where your runners are registered:

| Registered at | Which repositories it serves |
| --- | --- |
| Instance | **every repository on the instance** |
| Organization | that organization's repositories |
| Repository | that repository |

Gitea has no per-repository runner ACL; its FAQ points at registration scope
as the control instead, and gitea.com registers its own runners for a single
organization so they will not run other repositories' jobs.

**A repository's CI posture is that of the weakest runner it can reach, not
the one its workflow names.** So if the instance hosting these repositories
also offers general-purpose instance-level runners, hardening this one buys
less than it appears to. In rough order of preference:

1. Do not register general-purpose runners at instance level on an instance
   that hosts repositories receiving agent-authored branches.
2. Harden every runner that repository can reach, so landing elsewhere changes
   nothing that matters.
3. Move the repository to an instance or organization whose reachable runners
   are all hardened.

## Verify

Two failures matter here and both look exactly like success from inside a job:
a job container that was handed the Docker socket, and a job that can reach an
off-list address. Neither shows up as a red run. They show up as nothing at
all.

Nothing else in this repository can catch either. `install.sh` reports what it
wrote; `dejima-ci-runners` reports that a runner registered and is reading the
config it generated - and a runner can do all of that while granting its jobs
everything. The properties the tool exists for are only observable from inside
a job on the runner.

So `test/ci-runner.bats` runs there. It takes the tier from `DEJIMA_CI_TIER`
rather than sniffing it, so landing on the wrong runner fails instead of
quietly selecting a different set of assertions, and it skips entirely when
that variable is unset - which is why `bats test/` is still safe to run on a
laptop.

| | `confined` | `privileged` |
| --- | --- | --- |
| Docker socket absent | asserted | asserted **present** |
| Host network namespace | — | asserted |
| Allowlisted name resolves and connects | asserted | n/a |
| Off-list name refused | asserted | n/a |
| Off-list resolver on `:53` unreachable | asserted | n/a |
| Off-list address on `:443` unreachable | asserted | n/a |
| IPv6 not an unfiltered way around | asserted | n/a |

The egress half is scoped to the confined tier on purpose. The privileged
tier's jobs are in the host's network namespace, so the bridge rules are not
in front of them at all and asserting an allowlist there would test nothing
and pass anyway - which is the failure mode the file exists to catch.

Read the two together. If the DNS checks pass while the egress checks fail,
the resolver is fine and the packet filter is not. Each failure message names
the setting and the command to check it.

`.gitea/workflows/tests.yml` runs both tiers as `runner-env (confined)` and
`runner-env (privileged)`, one red check each, so a broken runner says which
one it was. A failure there means the machine needs attention, not the branch.

## Use

Confined-tier commands. A privileged host installs none of them, which is the
point of that tier rather than a gap in it.

```sh
sudo dejima-ci-allowlist check    # what would change, without changing it
sudo dejima-ci-allowlist render   # fetch, validate, install, reload if changed
sudo dejima-ci-allowlist show     # what is installed right now
sudo dejima-ci-firewall           # reapply the egress rules
```

All four need root, `show` included: every one of them reads
`/etc/dejima-ci/config`, which names a forge token's path and is `0640 root` in
a `0750 root` directory. Without `sudo` they cannot see it — and say that,
rather than reporting it as absent.

`dejima-ci-runners` is installed on both tiers, and is how the runners
themselves are changed:

```sh
sudo dejima-ci-runners --role confined --count 5 --non-interactive   # grow the pool
sudo dejima-ci-runners --role confined                               # change anything else
```

Exit codes are distinguishable on purpose, because a timer's alerting has to
tell "the allowlist moved" from "the forge is unreachable":

| | |
| --- | --- |
| `0` | nothing to do |
| `1` | `check` only - there is a pending change |
| `2` | a fault: bad configuration, an unreachable forge, a malformed entry |

A configuration problem lists **every** problem at once, each naming the
setting, the path it points at, and what belongs there.

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
  that will not start is a job network with no DNS at all.
- An unchanged allowlist is not reinstalled, so the log stays useful for
  spotting when it actually changed.

The firewall refuses to run without `ipset`, `iptables` and `ip6tables`, and
says what their absence costs. Without that check its first command fails and
the state it leaves behind resembles a working one: DNS still refuses unlisted
names, because that is the resolver's doing rather than the firewall's, while
every job has unrestricted egress.

## Tests

```sh
bats test/
```

Runs against a stubbed `curl`, `dnsmasq` and `docker`, so it needs none of
them and tells you what these programs decide rather than what the system does
afterwards.

`.gitea/workflows/tests.yml` runs that suite on every pull request, plus one
check the stubs cannot make: it renders both tiers with the real generator and
hands the output to a real `docker compose config`. A compose file can be
valid YAML - which is all `bats test/` establishes - and still be rejected by
Docker for a misspelled key or an anchor that does not merge. That job needs a
Docker daemon and the host's own egress, so it runs on the privileged tier,
and failing it means the runner needs attention rather than the branch.

## Further reading

| | |
| --- | --- |
| [docs/](docs/) | Index of everything below |
| [docs/reference.md](docs/reference.md) | The two `docker.sock` settings, `CONFIG_FILE`, the `/data` volume, compose networks against job networks, sharing a job network between runners, why the privileged runner is separate, why the resolver is per-runner, the cache server |
| [proxmox/README.md](proxmox/README.md) | Building the sacrificial VM: node firewall rules, bootstrap, snapshot, scheduled rollback |
| [dejima's `docs/ci.md`](https://gitbox.branderson.io/dejima/dejima/src/branch/main/docs/ci.md) | Why a CI runner needs any of this, and why there is no approval gate |

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

The dejima wordmark and logo are not code and are not covered by that licence.
They are trademarks; who holds them and what may be done with them is stated
once for the organisation, at
[dejima's ATTRIBUTION.md](https://gitbox.branderson.io/dejima/dejima/src/branch/main/ATTRIBUTION.md).
