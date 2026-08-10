# Threat model

What this defends, what it does not, and which options were rejected on
purpose. The last section matters most: it exists so a decision can be
overturned on new information rather than re-argued from nothing.

The sister project, [dejima-devbox-hardener](https://gitbox.branderson.io/dejima/dejima-devbox-hardener),
has a document of the same name for a machine that cannot be rolled back. The
difference between them is the whole reason there are two projects.

## The adversary

A pull request. Specifically, a branch whose contents were written by an agent
and whose author is assumed to be hostile.

That is not a hypothetical framing. The premise of this whole repository is that
CI executes attacker-controlled code on every pull request, deliberately,
because that is what CI is for. Nothing here is trying to stop the code running.
It is trying to bound what the code can reach while it runs.

## Ranked by what is actually likely

1. **A job reaching something on the operator's network.** A job runs
   dependencies, build scripts and fetched content. None of that needs an
   exploit to attempt a connection to another host.
2. **A job choosing its own runner.** `runs-on:` is written by whoever wrote the
   workflow, so a branch that can add a workflow can ask for the tier that
   grants more. This is why the register scope matters and the label does not.
3. **Root on the runner VM.** Assumed rather than defended against, on the
   privileged tier by construction. See below.

**Cross-project context poisoning is not a risk here.** A runner mounts no
`~/.claude` and runs no dejima session, so the channel the sister project's
threat model deals with has nothing to act on.

## The two tiers, and where each one's boundary is

**Confined.** The primary control is inside the VM: the job network, its
allowlisting resolver, and the `DOCKER-USER` rules. Those are real against a job
precisely because a job cannot reach them, and they decide egress by name and by
address. The node firewall sits behind that as defence in depth.

**Privileged.** There is no in-guest control worth the name, and that is the
grant the tier exists for: its jobs hold the Docker socket and run in the host's
network namespace. Root on that VM is the working assumption, not the worst
case, and root can flush any rule set it can see. The boundary is the hypervisor
firewall and the scheduled rollback.

## Blast radius by layer

| Layer | Reached by | Radius |
| --- | --- | --- |
| Confined job | normal operation | the allowlist, and nothing else on the LAN |
| Privileged job | normal operation | the Docker socket, which is root on the runner VM |
| Runner VM, root | a privileged job, or an escape from a confined one | the whole VM and its network position, until the next rollback |
| LAN | any of the above, if unbounded | every host the VM can route to |
| Hypervisor | out of scope | named for completeness |

Two rows are worth reading twice. A privileged job reaches root **by design**,
without any exploit, which is why that tier's containment is entirely external.
And every row is bounded in time as well as in reach, because the VM is rebuilt
from a snapshot on a schedule.

## Why container escape is not the interesting case here

Escapes are real and they recur: runc `CVE-2019-5736` and `CVE-2024-21626`,
containerd `CVE-2020-15257`, cgroups v1 `release_agent` `CVE-2022-0492`, and
kernel privilege escalations reachable from inside a container such as Dirty
Pipe and the `nf_tables` family.

**An escape grants more than the container had.** Root on the VM is strictly
more capability than a process in a job container.

It does not leave the model, though. Root on the runner VM is already a row in
the table above, reached on the privileged tier without any exploit at all. The
hypervisor firewall and the rollback bound that row, and bound it identically
however root was obtained. An escape from a confined job arrives at a place the
model already describes and already contains.

So escape moves a confined job to the privileged tier's threat position. That is
a real loss - the allowlist is gone - and it is bounded by the same two controls
the privileged tier relies on all the time.

## What rollback is doing, and what it is not

Rollback is this project's distinctive control and the reason a runner can be
treated so casually. Anything that gets in has until the next rebuild, and
nothing on the machine was worth keeping.

It is not a detection mechanism. It destroys evidence along with the intruder,
and it will happily rebuild a VM that was compromised through a route that is
still open. It buys time, not diagnosis.

This is exactly the control the sister project cannot have, because a devbox
holds uncommitted work. Everything that differs between the two repositories
follows from that one sentence.

## Rejected, with reasons

Recorded so they are not re-proposed without new information.

**An approval gate before CI runs.** Rejected upstream rather than here; see
[dejima's docs/ci.md](https://gitbox.branderson.io/dejima/dejima/src/branch/main/docs/ci.md).
The short version is that a human approving a diff they have not read is a
control in name only, and the ones who do read it are the bottleneck the agent
workflow exists to remove.

**Inverting `policy_out` to deny-by-default with a port allowlist.** Rejected in
full in `proxmox/firewall.fw.template`, and the argument is not repeated here so
that it lives in one place. Briefly: it breaks ordinary software in ways that
present as network faults, and it buys nothing against an adversary assumed to
have root, who tunnels over 443 like everyone else.

**Proxmox's `dhcp: 1` option.** Rejected because it is not reliably reachable
from the web console, and this runbook is console-driven on purpose. Two
ordinary rules do the same job and are narrower besides, naming a protocol and a
port rather than a host.

**Trusting the runner label as a boundary.** Rejected because it is not one.
`runs-on:` is written by whoever wrote the workflow. What decides which runners
a repository can reach is the scope the runner was registered at, and the README
says so under "Register scope is the boundary; the label is not".

## What this repository does not claim

It does not prevent a job from running hostile code. That is what CI is.

It does not prevent root on a privileged runner, which is granted rather than
defended. What it does is bound what that root reaches, and bound how long it
keeps it.
