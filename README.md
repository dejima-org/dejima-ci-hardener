# dejima-ci-hardener

Hardens a CI runner host that executes agent-authored code on every pull
request, and gives its jobs as little as possible to execute it with.

**This is the only thing you clone onto a CI box.** It is self-contained -
there is no step that copies files out of a dejima checkout, and dejima itself
never needs to be present here.

There are two kinds of runner host, and which one you are building changes
almost everything below. Pick the tier first, then follow only its half.

For *why* any of this is necessary - what a CI run adds over a sandbox, and
why no approval gate is offered - see dejima's `docs/ci.md`. You do not need
it to follow this.

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
| The boundary is | in the host | on the hypervisor |
| Treat this host as | expected to hold | already lost |
| Runs `install.sh` | yes | no, deliberately |
| For | tests, lint, anything needing no daemon | image builds, tests needing a real daemon or host networking |

**Confined** is where everything belongs that can go there. Its jobs get no
Docker socket, run on a bridge this tool creates, and reach only the domains
the served repositories declare in `.dejima/allowed-domains` on their `main`.
`install.sh` builds all of that, and it is reasonable to run on a machine you
already have.

**Privileged** exists for the jobs that cannot work otherwise: building a
Docker image, or dejima's own runtime tests, which assert things about a real
daemon and a real host network. Both grants are root-equivalent on the host,
and neither can be reduced without breaking the job they exist for. That tier
needs a machine built to be lost, not a machine you own.

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

# The confined tier

## Build or harden the host

Either works. On a machine you already have:

```sh
sudo apt-get install git ipset iptables dnsmasq docker.io
git clone https://gitbox.branderson.io/branderson/dejima-ci-hardener.git
cd dejima-ci-hardener
sudo ./install.sh
```

**`install.sh` installs no packages, so that line has to be complete.** It
configures a machine you already have, and quietly adding a Docker daemon to
one is not a thing it should do on your behalf. It checks for what it needs and
stops if anything is absent.

Two of those are easy to be missing on a fresh Debian. `git` is not installed
by a netinst at any task selection, including "standard system utilities" —
that task is `sudo` and the base tooling. And `docker.io` is what `install.sh`
creates the job network with, which is the first thing it does. On trixie the
client is a separate `docker-cli` package that arrives as a recommendation of
`docker.io`; if you install with `--no-install-recommends`, name it too.

On a fresh VM, [proxmox/README.md](proxmox/README.md) builds one and
`dejima-ci-bootstrap` finishes it - packages, sshd, unattended upgrades, the
host's own egress policy, and then `install.sh` for the job allowlist:

```sh
sudo ./bin/dejima-ci-bootstrap --role confined --mgmt <your-ip>
```

That path needs none of the apt line above: installing those packages is the
first thing `dejima-ci-bootstrap` does, Docker included.

## What `install.sh` does

It prompts for each value, offering whatever is already configured as the
default, and does the whole job: creates the Docker network with a fixed
bridge name, writes the resolver config, installs `dejima-ci-allowlist` and
`dejima-ci-firewall`, installs and enables the systemd units, and renders the
first allowlist.

**Idempotent** - re-running and pressing Enter at every prompt changes
nothing, so it is also how to change one setting later.
`--non-interactive` re-installs from the existing configuration.

What it asks for:

| | |
| --- | --- |
| Job network | name, bridge, gateway and subnet - a **private** range |
| Forge URL | `https://gitea.example.com` - the API root is derived |
| Upstream resolver | see below; it offers what this host already uses |
| Forge token | read access only, never echoed, kept if one is already installed |
| Repositories | `owner/repo` per line - adding one trusts that repository's `main` |
| Base domains | allowed regardless of any project declaration |

## The upstream resolver

The one setting that is genuinely ambiguous, so: it is the resolver **dnsmasq
forwards allowed queries to** - the one that actually knows the answers.

It is *not* the dnsmasq this configures (that would loop), and *not* the job
bridge gateway. It is whatever this host already resolves with:

```sh
grep nameserver /etc/resolv.conf
```

On a host running systemd-resolved that gives you `127.0.0.53`, the local
stub, which is not an answer - `resolvectl status | grep 'DNS Servers'` is,
and names the servers behind it. Anywhere else `resolvectl` is simply absent,
including on a VM built by the runbook above. Do not install it to find this
out; `/etc/resolv.conf` is the answer on that machine.

It has to resolve everything on the allowlist, **including your forge** - so
if that name is internal, this has to be your internal DNS. `no-resolv` in the
dnsmasq config means it will not read `/etc/resolv.conf` itself, which is why
it must be named explicitly.

## The runners

`install.sh` offers to do this at the end, and it is the same command either
way:

```sh
sudo dejima-ci-runners --role confined
```

It writes a compose project to `~/runners` - `docker-compose.yml`,
`config.yaml` and a `0600` `.env` - brings it up, and then checks each runner
actually registered rather than assuming it did.

It asks for a label and how many runners you want. It does **not** ask for the
job network or the resolver address: those come from the config `install.sh`
wrote, because they have to match what it built, and a value that has to match
something else is not a value to retype. That was the failure this replaces -
`container.network`, `--dns` and `CONFIG_FILE` were three things to keep in
step by hand, and each of them drifts silently, leaving a runner that starts,
accepts jobs, and filters nothing.

The one thing it cannot do is mint the registration token, which lives in your
forge's UI. It prints the exact page for the scope you want and waits.

To change something later - another runner, a different label, a new
`act_runner` image - re-run it. Re-running with the same answers changes
nothing, so it is safe to do casually:

```sh
sudo dejima-ci-runners --role confined --count 5 --non-interactive
```

`examples/` holds the annotated templates it renders. Read them there to see
why each setting is what it is; the rendered copies say `DO NOT EDIT` because
the next run overwrites them. `examples/docker-daemon.json` is the exception -
it is not rendered, and goes into `/etc/docker/daemon.json` by hand, merged
rather than overwritten.

Register at **repository or organization** scope - see [Register scope is the
boundary](#register-scope-is-the-boundary-the-label-is-not).

---

# The privileged tier

## Build the VM. Do not harden an existing one.

`install.sh` hardens the runners on a machine you already have. For this tier
that is the wrong starting point - its jobs get the Docker socket, so the
assumption has to be that a compromised job gets root on that host, and
handing an existing machine to that assumption is not a decision many people
would make deliberately.

**[proxmox/README.md](proxmox/README.md)** builds one instead: a runbook for
the Proxmox web console, then one script inside the VM.

```sh
# inside the new VM, once the console steps are done
sudo ./bin/dejima-ci-bootstrap --role privileged --mgmt <your-ip>
```

The node half is a runbook rather than a script on purpose. Something that
runs `qm create` and writes into `/etc/pve/firewall/` is exactly what gets
pasted into a root shell unread, and the blast radius is every VM on the node.
The in-VM half is a script, because running that one blind costs you a machine
built to be lost.

## The boundary is on the node, not in the VM

Everything installed inside the VM is defence in depth: real against a
compromised job that has not escaped its container, which is the ordinary
case, and worth nothing against one that has.

What holds either way is the Proxmox firewall, applied to the VM's tap device
and unreachable from the guest. It denies the VM every RFC1918 destination
except two pinholes - the forge on 443 and a resolver on 53 - and those two
are the entire remaining LAN exposure. Public egress is deliberately *not*
restricted there;
[docs/reference.md](docs/reference.md#why-public-egress-is-not-restricted-on-the-node)
says why, and why a port allowlist there bought nothing.

One thing to check rather than assume, because its absence looks exactly like
it working: **the datacenter firewall must be enabled** (Datacenter → Firewall
→ Options → Firewall: Yes), and the VM's network device must have its own
**Firewall** checkbox ticked. Without either, the per-VM rules apply to
nothing. `pve-firewall compile` on the node is the check, and
[proxmox/README.md](proxmox/README.md) has a from-inside-the-VM check that
does not rely on reading configuration at all.

## Snapshot, and roll back on a cadence

The VM is worth losing, which is only true if losing it is cheap. Register the
runner, then snapshot - **VM → Snapshots → Take Snapshot**, named `clean`,
**before the first job runs** and with *Include RAM* unticked. One taken later
preserves whatever that job left; one taken before registration drops the
runner off the forge on every rollback; one with RAM restores the guest's clock
along with it, and a VM that thinks it is last month cannot verify a
certificate.

Rolling back after anything suspicious is not optional. Rolling back *on a
schedule* is the more valuable of the two, because it does not depend on your
having noticed - and it is the one that stops happening once doing it by hand
gets old. Proxmox schedules backups, not rollbacks, so it is a cron entry on
the node; [proxmox/README.md](proxmox/README.md) §6 has the line, why each part
of it is what it is, how to confirm it is still running, and why the baseline
needs refreshing every month or two.

## The runner

`dejima-ci-bootstrap` offers to do this at the end. On its own:

```sh
sudo dejima-ci-runners --role privileged --forge https://gitea.example.com
```

Same command as the other tier, same `~/runners` project, same registration
check. Three things differ, and each follows from the tier rather than being a
setting you pick:

- **One runner, not asked.** A second runner here would share the machine that
  is already assumed lost rather than getting one of its own.
- **`--forge` is required.** There is no `install.sh` config on this host to
  read it from, because `install.sh` never runs here.
- **It asks which host paths jobs may bind-mount.** A volume a workflow asks
  for and `valid_volumes` does not name is dropped *silently*, so this has to
  match what your workflows request. `none` allows nothing.

There is no `--dns` to set and no job network to join: its jobs are in the
host's namespace, which is the grant the tier exists for.

Give it one label that nothing else carries, and grant it to as few
repositories as you can stand. Then **take the clean snapshot** - see
[proxmox/README.md](proxmox/README.md) §5. A snapshot taken after the first
job has run preserves whatever that job left.

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
dejima-ci-allowlist check    # what would change, without changing it
dejima-ci-allowlist render   # fetch, validate, install, reload if changed
dejima-ci-allowlist show     # what is installed right now
dejima-ci-firewall           # reapply the egress rules
```

`dejima-ci-runners` is installed on both tiers, and is how the runners
themselves are changed:

```sh
dejima-ci-runners --role confined --count 5 --non-interactive   # grow the pool
dejima-ci-runners --role confined                               # change anything else
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
| dejima's `docs/ci.md` | Why a CI runner needs any of this, and why there is no approval gate |

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
