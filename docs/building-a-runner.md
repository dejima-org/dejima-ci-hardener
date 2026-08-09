# Building a runner host

Everything done *inside* the VM, for either tier. Nothing here is specific to
a hypervisor: it assumes a fresh Debian on a machine you are willing to lose,
with whatever isolation your hypervisor provides already in place.

**On Proxmox, do [the node-side steps](../proxmox/README.md) first** — the
datacenter firewall, the VM itself, and the firewall rules applied to it. Come
back here once the installer has booted. On anything else, the equivalent is:
a VM that reaches the internet and, on your LAN, only your forge and a
resolver.

Two moments below need your hypervisor rather than this page, both snapshots.
They are one line each and linked where they fall.

---

## 1. Install Debian


Install Debian normally, with two things to get right while it runs.

**Leave the root password blank.** Debian reads an empty root password as
"use sudo", installs it, and puts your first user in the `sudo` group. Set a
root password instead and it does neither — your user has no `sudo` at all,
and the bootstrap step below opens with two `sudo` commands that will tell you
so.

If you have already set one, fix it from the console as root:

```sh
apt-get install -y sudo
usermod -aG sudo <your-user>
```

then log out and back in — group membership is read at login, so the shell you
are already in will not have it.

**The software selection screen.** This is the one that bites, because it is
a checklist where the defaults are wrong for this machine and clearing them
all is worse. Navigate with the arrow keys and toggle with **space** — typing
does nothing useful, and clearing every entry leaves you without the tools the
next section assumes.

| Entry | Set it to |
| --- | --- |
| Debian desktop environment (and any desktop under it) | **off** |
| web server | off |
| **SSH server** | **on** — this is how you reach the VM, and nothing here installs it later |
| **standard system utilities** | **on** — the one that quietly costs you the most if it is off; see below. It does *not* give you `git`; see §4 below |

Leave SSH server *on*, even though `dejima-ci-bootstrap` configures sshd
later. Configuring is not installing: skip the task and the VM has no sshd to
configure and no way in except your hypervisor's console.

**Leave standard system utilities on as well.** It is where `sudo` comes from,
and `dbus` with it. `systemctl` reaches the service manager over the system
bus, so a host without `dbus` cannot start, stop, enable or reload anything -
while `systemctl` on a unit that does not exist still answers normally, which
makes the state easy to miss.


---

## 2. Addressing: leave it on DHCP

A runner wants an address that stays put — you reach this machine by it for the
life of the VM, and a lease that moves is a machine you have to go and find.

The installer will not have asked. With a working DHCP server on the segment it
configures the interface and moves on, and there is no static-or-DHCP question
to answer.

**Do nothing about that here.** §4's `dejima-ci-bootstrap` pins this host to the
address it already has — same address, same gateway, same resolver, read off
the running interface rather than typed — so there is nothing to transcribe and
nothing about reachability changes at the moment it runs. Leaving it until then
also means the values it copies are ones you have just watched work.

Two things it cannot do for you:

- **Reserve the address**, on your DHCP server or by putting it outside the
  pool. Until that is done the server is free to hand the same one to something
  else.
- **Prove it survives a restart**, which is the only real test of an addressing
  change. §4 takes a snapshot before any of this, so the way to find out costs
  nothing.

**What a moving address does *not* break.** Not the firewall. Every rule in
[the node firewall](../proxmox/README.md#3-the-firewall-rules) keys on a
*destination*, except the SSH rule, which keys on *your* management address —
and it is applied to this VM's virtual interface, identified by the VM rather
than by its address. Nothing anywhere names this VM by its own
address, so a rebuilt VM that comes up on a different one is still fully
firewalled.

What it breaks is you finding the machine: `ssh <you>@<vm-ip>` in §4, and every
later visit. That is reason enough to pin it.

---

## 3. Check the base, then snapshot it

Everything so far is a stock Debian with its networking settled. Everything
after is a script making changes across the machine. Check the base is sound,
then preserve it — a bad run becomes a revert rather than an investigation,
and the machine stays identical to what this page describes rather than to
whatever a half-finished run left.

```sh
ip -o -4 addr show scope global      # the address you meant
ip route | grep default
getent hosts deb.debian.org          # a public name
getent hosts <your-forge-hostname>   # and yours
systemctl is-system-running          # running, not degraded
```

All five have to answer before going on. The last one matters more than it
looks: `systemctl` reaches the service manager over the system bus, and a host
without `dbus` cannot start, stop, enable or reload anything — which is most of
what the next step does.

Then take a snapshot named `preflight`, with RAM excluded.
**Proxmox: [§4, Snapshots and rollback](../proxmox/README.md#4-snapshots-and-rollback).**

---

## 4. Build it

Both tiers are the same command with a different flag. Pick the one you
decided on in [the README's tier table](../README.md#two-tiers-and-you-must-pick-one);
if you have not decided, that table is the decision.

```sh
ssh <you>@<vm-ip>
sudo apt-get update && sudo apt-get install -y git
git clone https://gitbox.branderson.io/dejima/dejima-ci-hardener.git
cd dejima-ci-hardener

sudo ./bin/dejima-ci-bootstrap --role confined   --mgmt <your-management-ip>
#                                     ^^^^^^^^ or: privileged
```

**`git` is a real step, not a precaution.** A Debian netinst does not install
it at any task selection, including "standard system utilities" — that task is
`sudo` and the base tooling, and `git` is not in it. `dejima-ci-bootstrap`
installs `git` too, which does not help here: you need it to fetch the script
that would install it. This one line is the bootstrap's own bootstrap.

Two ways this stalls, both from choices made during the install:

- **`ssh` refuses the connection** — the SSH server task was not selected. Log
  in at your hypervisor's console, which needs no network, and
  `apt-get install -y openssh-server git`, then `systemctl enable --now ssh`.
- **`sudo` says you are not in the sudoers file** — a root password was set
  during the install, so Debian did not add you. See §1 for the fix, or just
  run these as root from the console.

### What it does, on both tiers

It checks this host can resolve, offers to [pin the
addressing](#2-addressing-leave-it-on-dhcp), installs packages, removes
listeners a runner has no use for, hardens sshd, installs `qemu-guest-agent`
so the hypervisor can freeze this filesystem for a consistent snapshot and shut
it down by negotiation rather than by ACPI alone, and enables unattended
security upgrades.

The packages are worth a word, because they are not a list you could usefully
paste from a README. `install.sh` needs Docker; `dejima-ci-runners` needs
Compose; Compose has no single package name that works across releases, since
`docker-compose-v2` does not exist before trixie and the fallbacks are
backports and then Docker's own apt repository. Debian also splits the Docker
client into `docker-cli`, which `--no-install-recommends` drops, leaving a
daemon and no `docker` binary. The script tries each route and checks the
result rather than trusting apt's exit code.

### What it does only on `--role confined`

It then runs `install.sh`, which builds the job network, its allowlisting
resolver and the DOCKER-USER rules that filter job egress. And it installs the
host's own outbound policy, denying this machine every RFC1918 destination
except its resolvers and its forge — both derived rather than asked for, the
resolvers from `/etc/resolv.conf` and the forge from the URL `install.sh` just
recorded — then turns it on and checks the forge still resolves, taking it
back off if it does not.

None of that happens on `--role privileged`, and the reason is the same for
every part of it: a job there holds the Docker socket and runs in this host's
network namespace, so it can flush any of those rules in one command.
Installing them would leave a host that
[looks filtered and is not](../README.md#the-privileged-tier-has-no-egress-allowlist-on-purpose),
which is worse than one that plainly is not. What contains that tier is the
hypervisor's firewall, which the guest cannot reach.


---

## 5. What `install.sh` asks for

`--role confined` only; the privileged tier never runs it.

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

### The upstream resolver

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
including on a VM built by these steps. Do not install it to find this
out; `/etc/resolv.conf` is the answer on that machine.

It has to resolve everything on the allowlist, **including your forge** - so
if that name is internal, this has to be your internal DNS. `no-resolv` in the
dnsmasq config means it will not read `/etc/resolv.conf` itself, which is why
it must be named explicitly.

### Running it again, later

It is a separate program and stays one, but not because building a host is a
two-step job. It is what you run **afterwards**, to change something:

```sh
sudo ./install.sh          # add a repository, change the forge, move the resolver
```

It is idempotent, so pressing Enter at every prompt changes nothing, and
re-running the whole bootstrap to edit one setting would mean another
`apt-get update`, another sshd rewrite and another egress policy install to
change a line in a config file.

It installs no packages, on the grounds that adding a Docker daemon to a
machine is not a thing to do on someone's behalf — so on a host that
`dejima-ci-bootstrap` did not build, it stops and names what is missing rather
than fetching it. That is the deliberate case; the ordinary one is that
bootstrap already put them there.

Note what running it alone leaves undone: **the host hardening.** You get the
job network, the allowlist, the resolver and the DOCKER-USER rules, on a
machine that still answers on every listener the install left running, with
whatever sshd configuration it came with. The confined tier's controls sit in
front of jobs, not in front of the host.

---

## 6. The runners

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
boundary](../README.md#register-scope-is-the-boundary-the-label-is-not).

### On `--role privileged`

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
repositories as you can stand. Then take the clean snapshot, which §7 below
covers for both tiers.

### More than one registration token on the same host

A registration token is minted at a scope — an organization, or a user
account — and serves only repositories inside it. To serve two scopes from one
host, register two groups:

```sh
sudo dejima-ci-runners --role confined --name dejima     --label ci-shared
sudo dejima-ci-runners --role confined --name branderson --label ci-shared
```

Each gets its own directory, compose project, containers, volumes and `.env`,
so the tokens never meet and either group can be changed or removed without
touching the other. Run the command again per group; it is idempotent, so the
first is undisturbed by the second.

**The label may be the same for both, and usually should be.** It is what a
workflow names in `runs-on:`, and a job from either scope should be able to
reach a runner. That is why the group name is a separate thing: sharing an
identity as well would collide on the compose project and the container names,
and the second group would replace the first rather than join it.

What the group name must not be shared with is another group. Everything the
host uses to tell them apart is derived from it.

---

## 7. Snapshot it clean, once the runner is registered

The VM is worth losing, which is only true if losing it is cheap. The runner's
identity lives on disk, in its `.runner` file, so a snapshot taken before
registration drops the runner off the forge on every rollback — and one taken
after the first job preserves whatever that job left, which is precisely what
you want to be able to throw away.

**Restart the VM before you snapshot it**, and check it comes back. This is the
step that proves the addressing written in §4: a static configuration takes
effect at boot and not before, so until the machine has booted once with it,
nobody has tested it — including you.

It matters here rather than anywhere else because rolling back *is* a cold
boot. The disk is restored and the VM is started, so every rollback re-applies
that configuration and re-runs every unit. Snapshot a machine whose network
configuration has never been proven and you have not frozen a working state;
you have frozen an untested one, and the cadence will apply it unattended, on a
schedule, every time.

```sh
ip -o -4 addr show scope global      # the address you pinned, after a real boot
ip route | grep default
getent hosts <your-forge-hostname>
systemctl is-system-running          # running, not degraded
```

Then confirm the runner shows **Online** in your forge, and snapshot, named
`clean`, before the first job runs.
**Proxmox: [§4, Snapshots and rollback](../proxmox/README.md#4-snapshots-and-rollback)**,
which also covers rolling back on a schedule — the half that does not depend on
your having noticed anything.

If any of those four fail, fix the cause and restart again before snapshotting.
A `clean` taken now is the state you return to indefinitely, so it is worth one
more boot to know it is the state you meant.

---

## Next

The host is built. What it is *not* is verified: whether job containers get the
Docker socket, and whether they can reach an off-list address, are only
observable from inside a job.

**→ [Verify](../README.md#verify)**
