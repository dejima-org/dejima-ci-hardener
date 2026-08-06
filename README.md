# dejima-ci-hardener

Hardens a CI runner that executes agent-authored code on every pull request,
and gives it as little as possible to execute it with: no Docker socket in job
containers, and deny-by-default egress whose allowlist comes from
`.dejima/allowed-domains` on each served repository's `main`.

**This is the only thing you clone onto a CI box.** It is self-contained -
there is no step that copies files out of a dejima checkout, and dejima itself
never needs to be present here.

For *why* any of this is necessary - what a CI run adds over a sandbox, and
why no approval gate is offered - see dejima's `docs/ci.md`. You do not need
it to follow this.

## The runner host itself

`install.sh` hardens the runners on a machine you already have. For the
privileged tier that is the wrong starting point - its jobs get the Docker
socket, so the assumption has to be that a compromised job gets root on that
host, and handing an existing machine to that assumption is not a decision
many people would make deliberately.

**[proxmox/README.md](proxmox/README.md)** builds one instead: a runbook for
the Proxmox web console, then one script inside the VM.

```sh
# inside the new VM, once the console steps are done
sudo ./bin/dejima-ci-bootstrap --role runtime --mgmt <your-ip>
```

The node half is a runbook rather than a script on purpose. Something that
runs `qm create` and writes into `/etc/pve/firewall/` is exactly what gets
pasted into a root shell unread, and the blast radius is every VM on the node.
The in-VM half is a script, because running that one blind costs you a machine
built to be lost.

### The boundary is on the node, not in the VM

The privileged tier hands job containers the Docker socket, which is
root-equivalent on their host. So the working assumption is that a compromised
job **has root in that VM** — and root can flush any firewall it can see.

Everything installed inside the VM is therefore defence in depth: real against
a compromised job that has not escaped its container, which is the ordinary
case, and worth nothing against one that has.

What holds either way is the Proxmox firewall, applied to the VM's tap device
and unreachable from the guest. It denies the VM every RFC1918 destination
except two pinholes — the forge on 443 and a resolver on 53 — and those two
are the entire remaining LAN exposure.

Public egress is deliberately *not* allowlisted there. Job containers already
have an allowlist, enforced inside the VM; duplicating it by IP on the node
would break on every CDN rotation and would not hold against VM root anyway.
The guarantee is narrower and more honest: an attacker who owns that VM
reaches the internet, and not your network.

One thing to check rather than assume, because its absence looks exactly like
it working: **the datacenter firewall must be enabled** (Datacenter → Firewall
→ Options → Firewall: Yes), and the VM's network device must have its own
**Firewall** checkbox ticked. Without either, the per-VM rules apply to
nothing. `pve-firewall compile` on the node is the check, and
[proxmox/README.md](proxmox/README.md) has a from-inside-the-VM check that
does not rely on reading configuration at all.

### Snapshot, and roll back on a cadence

The VM is worth losing, which is only true if losing it is cheap. Snapshot it
the moment it is bootstrapped and before any job has run:

**VM → Snapshots → Take Snapshot**, named `clean`, taken **before the first
job runs** — one taken later preserves whatever that job left. Roll back from
the same tab.

Rolling back on a schedule bounds how long a foothold can live without needing
the VM rebuilt each time. Weekly is a reasonable starting point; after
anything suspicious is the other trigger, and that one is not optional.

## Do not install this next to dejima

This runs on a machine whose job is to execute untrusted code. dejima runs on
a machine you care about. Putting both on one host defeats the separation that
makes either worth anything, and this program holds a forge token and rewrites
a resolver's configuration - neither of which belongs within reach of a
sandbox session.

## Install

```sh
sudo apt-get install ipset iptables dnsmasq
git clone https://gitbox.branderson.io/branderson/dejima-ci-hardener.git
cd dejima-ci-hardener
sudo ./install.sh
```

`install.sh` prompts for each value, offering whatever is already configured
as the default, and does the whole job: creates the Docker network with a
fixed bridge name, writes the resolver config, installs
`dejima-ci-allowlist` and `dejima-ci-firewall`, installs and enables the
systemd units, and renders the first allowlist.

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

### The upstream resolver

The one setting that is genuinely ambiguous, so: it is the resolver **dnsmasq
forwards allowed queries to** - the one that actually knows the answers.

It is *not* the dnsmasq this configures (that would loop), and *not* the job
bridge gateway. It is whatever this host already resolves with:

```sh
resolvectl status | grep 'DNS Servers'    # systemd-resolved
grep nameserver /etc/resolv.conf          # otherwise
```

It has to resolve everything on the allowlist, **including your forge** - so
if that name is internal, this has to be your internal DNS. `no-resolv` in the
dnsmasq config means it will not read `/etc/resolv.conf` itself, which is why
it must be named explicitly.

### The runners

`install.sh` does not register runners - that needs a token from your forge
and is the one step it cannot do for you. `examples/` has the configuration
they need:

| File | Install as |
| --- | --- |
| `examples/act-runner-ci.yaml` | the ordinary runner's `config.yaml` |
| `examples/act-runner-runtime.yaml` | the privileged runner's, on its own host |
| `examples/docker-compose.yml` | several ordinary runners on one host |
| `examples/docker-compose-runtime.yml` | the privileged one |
| `examples/docker-daemon.json` | `/etc/docker/daemon.json` - merge, do not overwrite |

Set `--dns=<your gateway>` in the ordinary runner's `container.options`, and
register at **repository or organization** scope. That last part is not
housekeeping — see below.

### Register scope is the boundary; the label is not

A dedicated label routes honest jobs to the runner you prepared. It stops
nothing else, because `runs-on:` lives in the workflow file and the workflow
file lives in the branch. A branch can name any label it likes, so a session
that changes `runs-on: dejima-ci` to `runs-on: ubuntu-latest` and opens a pull
request has stepped outside everything this tool installs — provided some
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
off-list address. Neither shows up as a red run.

dejima ships `test/ci-runner.bats` for exactly this, run by its own CI as
`runner-env (sandbox)` and `runner-env (host-docker)`. Point it at your runner
and it will tell you which half is wrong - if the DNS checks pass while the
egress checks fail, the resolver is fine and the packet filter is not.

## Use

```sh
dejima-ci-allowlist check    # what would change, without changing it
dejima-ci-allowlist render   # fetch, validate, install, reload if changed
dejima-ci-allowlist show     # what is installed right now
dejima-ci-firewall           # reapply the egress rules
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

Runs against a stubbed `curl` and `dnsmasq`.

---

# Reference

Everything below is background. You do not need it to complete the setup.

## The two settings named `docker.sock`

The compose bind and `container.docker_host` name the same path and do
opposite jobs. This is the easiest thing here to conflate:

| | Effect | Needed? |
| --- | --- | --- |
| The compose bind | The runner can reach the daemon | Yes — without it nothing runs |
| `docker_host: "-"` | Job containers *cannot* | Yes — without it every job is root on this host |

Setting the second does not remove the first, and removing the first does not
make jobs safe — it just stops the runner working.

Whether a job gets the socket is a property of **the runner**, not of the job:
a job asking for nothing unusual still receives whatever its runner grants
everything it runs.

## `CONFIG_FILE`, and why an edit can appear to do nothing

Without `CONFIG_FILE=/config.yaml` in the environment, `act_runner` does not
read the config file **at all** — it starts happily on built-in defaults,
which means the socket goes into every job container and nothing in any log
says so. If a config change appears to have no effect, check this first.

Mount the config read-only: a runner has no reason to rewrite the file that
decides what its jobs are granted.

## The `/data` volume

It holds `.runner`, written at registration: the runner's identity and its
credential for your forge (`runner.file: .runner`, resolved against the
container's working directory, which is `/data` in the official image).

- **Keep it** and `--force-recreate`, an image bump or a reboot brings back
  *the same registered runner*. Without it the container comes up with no
  identity — with a token still in the environment it silently registers a
  *new* runner, leaving a dead entry in your forge's runner list; without one
  it fails to start.
- **Delete it deliberately** to re-register: a runner moved to another
  instance, or a label set you would rather establish fresh.
- **It is the only state.** Nothing else in the container is worth preserving,
  which is what lets the rest of this treat a runner as disposable.

Labels come from `runner.labels` on every start rather than being frozen at
registration, so changing one is an edit and a restart.

## Compose networks and the job network are different worlds

Running several runners from one compose file makes them share a network — and
that is not the network worth worrying about.

Every service in that file is an `act_runner` *process*. The containers that
execute agent-authored code are created by the *daemon*, on the network named
by `container.network`, and compose knows nothing about them. Attaching a
service to a compose network does not put its jobs there.

So the shared network holds runner processes and nothing else, and those are
mutually trusted — each already holds the Docker socket, so separating them
protects nothing. The example names one `runners` network explicitly rather
than relying on the implicit `default`, so nothing joins it later by accident.

The compose file deliberately does **not** attach a runner to the job network
(a process holding the socket has no business sharing a network with untrusted
code), and does **not** put the runner behind the egress allowlist (those rules
filter the job bridge only — the runner is trusted, the jobs are not).

## Several runners, and whether they should share a job network

What *is* shared, with one compose file or five, is the job network: every
runner whose config names `dejima-ci` puts its jobs on that bridge. With N
runners at `capacity: 1` you get up to N jobs there at once, able to reach each
other and each other's service containers.

- **One shared job network** — the default, and why several runners can share
  one config file. Every job on it has the same egress allowlist and none can
  reach the host or the runners, so the added exposure is strictly job-to-job.
  If the concern is a prompt-injected session reaching *outward*, this already
  covers it.
- **One per runner** — worth it if concurrent jobs come from repositories that
  should not interfere, or if service containers hold anything a neighbour
  should not see. Costs a config file and a `docker network create` each, and
  the firewall rules looped over each bridge.

  The `ci-allow` ipset is shared either way — it holds destinations, not
  per-bridge state, so one set and one dnsmasq serve every bridge. The wrinkle
  is DNS: `daemon.json`'s `dns` is a single daemon-wide address that would sit
  on one bridge and be unreachable from the others. Give dnsmasq a stable
  address on a dummy interface, point `daemon.json` there, and let each
  bridge's `INPUT` rule allow port 53 to it.

## Why the privileged runner is separate

It is handed the Docker daemon and the host's network namespace, because one
job cannot work without them and neither grant can be reduced without breaking
it. A job on it can take the machine it runs on — so that machine should exist
for nothing else. A separate compose file makes a separate host the default,
rather than something to disentangle later.

Where the two tiers do share a machine, be clear about what that is: **label
tiering, not host separation.** A job denied the socket still shares a kernel
with a runner that has it. A real reduction over granting everything to
everything; not isolation between the tiers.

It needs no bind for `/tmp/dejima-ci` — the job container gets that path
because the workflow asks for it and `container.valid_volumes` permits it, and
the host daemon resolves the source host-side.

## Why the resolver is set per-runner, not daemon-wide

`daemon.json` has a `dns` key, and pointing it at the allowlisting resolver is
the obvious way to make job containers use it. It is also wrong here, and the
failure is not obvious.

That setting applies to **every container the daemon starts**. On a host that
also runs the privileged tier, that includes containers created by its jobs
over the Docker socket — which are not job containers and were never meant to
be behind the CI resolver.

A dejima sandbox is exactly such a container, and it has a firewall of its
own. It allowlists precisely one host address: its own bridge gateway, taken
from its default route. A resolver on a *different* bridge is therefore
rejected by the sandbox's own rules, so nothing inside it resolves — and the
symptom is not "DNS is misconfigured" but the sandbox's startup self-check
reporting that a host it allows is unreachable.

`--dns` in `container.options` scopes the resolver to the containers that
runner starts, which is the set that should have it.

## The cache server

`act_runner` enables it by default, and it binds on the host *specifically* so
job containers can reach it — an inbound service exposed to untrusted code. The
firewall here blocks exactly that. Leave it off, or add a rule knowing what you
are exposing.
