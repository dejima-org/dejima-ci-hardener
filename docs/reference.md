# Reference

Background. You do not need any of it to complete the setup - the
[README](../README.md) is self-contained. This is where the reasoning lives
for the decisions that look arbitrary from outside, and the failure modes that
present as something other than what they are.

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

`dejima-ci-runners` sets both, and checks after starting that `CONFIG_FILE` is
what it wrote — it is the one variable whose absence makes every other setting
inert, so it is verified rather than assumed. That check is worth knowing about
if you ever hand-edit the generated compose file: removing it there produces a
runner that looks configured and is not.

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

## Why public egress is not restricted on the node

The Proxmox firewall in [proxmox/README.md](../proxmox/README.md) denies the
privileged VM every RFC1918 destination and leaves the public internet to the
default policy. That asymmetry is deliberate.

An address allowlist there would break on every CDN rotation. A port allowlist
buys nothing: permitting only tcp/80, tcp/443 and udp/123 breaks apt on a first
install, and each breakage presents as a network fault rather than as a
firewall rule. Anyone who owns that box tunnels over 443 like everybody else,
and neither restriction would hold against VM root in any case.

Deny-by-default earns its keep where the protected set is enumerable, which is
the LAN. The internet is not, and treating it as though it were gets you a rule
set that looks strict and only gets in the way.

Note what that leaves. On the privileged tier there is no egress allowlist in
front of job containers either — they are in the host's network namespace, so
nothing is in front of them. A privileged job reaches the whole public
internet by design. What it does not reach is your LAN.

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
