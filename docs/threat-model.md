# Threat model

**And none of it has been reviewed by anyone else.** This is early development:
the reasoning here is one person's, the tests assert what that person thought to
check, and no outside audit or adversarial testing has happened. Read what
follows as claims awaiting scrutiny rather than claims that have survived it.
See [SECURITY.md](../SECURITY.md).

What this defends, what it does not, and which options were rejected on
purpose. The last section matters most: it exists so a decision can be
overturned on new information rather than re-argued from nothing.

The sister project, [dejima-devbox-hardener](https://gitbox.branderson.io/dejima/dejima-devbox-hardener),
has a document of the same name for a machine that cannot be rolled back. The
difference between them is the whole reason there are two projects.

## What this tool assumes

**That `main` is reviewed before it is merged.** Not a nicety attached to the
end of a security document. A dependency of the controls in it.

`dejima-ci-allowlist` reads `.dejima/allowed-domains` from `origin/main`, never
from a branch and never from a local checkout, and treats what it finds there
as already reviewed. That is the whole mechanism by which a branch is denied
the ability to widen its own egress: the answer comes from somewhere a branch
cannot write. The only way content reaches `main` is a pull request somebody
merged, so **the allowlist is exactly as trustworthy as the merges are.**

Merging a diff without reading it is therefore not a lapse this tool
compensates for. It is how a widened allowlist arrives, with the tool then
serving it faithfully and correctly.

dejima's [responsible-use.md](https://gitbox.branderson.io/dejima/dejima/src/branch/main/docs/responsible-use.md#safe-and-responsible-are-not-the-same-thing)
draws the line as safe against responsible: what a session can reach is the
sandbox's business, what you let out of it is yours. Nothing here does the
second job, and several things here depend on it being done.

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

## The LAN boundary is two boundaries

The node's control against lateral movement is a list of ranges dropped on the
hypervisor, and a list bounds only what it names. This one named IPv4 ranges
only, until it was found not to.

That is not the kind of gap where a control turns out weaker than advertised. It
is the kind where it does not apply, on a path that is open by default on every
network - including networks with no IPv6 anywhere in them. Every Linux host
brings up an `fe80::` address on every interface whether or not anything routes
v6, and a daemon bound to `::` answers on it. So the machine beside a runner was
reachable across the segment with all four DROPs in force and `ip -4 route`
showing nothing unusual.

**IPv6 has no RFC 1918.** The v4 list works because three ranges cover every
private network there is. A v6 network is numbered out of a globally routable
prefix delegated by an ISP, so no equivalent list can be written down:
`fc00::/7` catches unique-local addresses most networks do not use and misses
the prefix a neighbour is actually on. The set cannot be enumerated, so the
family is dropped whole, on the node, as rule 10 of the security group.

**`dejima-ci-firewall` was already doing this one layer in, and it is not the
same layer.** It rejects IPv6 on the job network for exactly the reason above -
an address family with no allowlist is not a smaller hole than the one the v4
rules close. But it covers a confined job reaching off its bridge. It is not in
front of the VM's own traffic, and on the privileged tier it is not in front of
the jobs either, because those run in the host's network namespace where the
bridge rules do not apply.

So the in-guest rule and the node rule cover different rows of the table below,
and the row the node rule covers is the one the privileged tier reaches during
ordinary operation rather than under attack.

## Blast radius by layer

| Layer | Reached by | Radius |
| --- | --- | --- |
| Confined job | normal operation | the allowlist, and nothing else on the LAN |
| Privileged job | normal operation | the Docker socket, which is root on the runner VM |
| Runner VM, root | a privileged job, or an escape from a confined one | the whole VM and its network position, until the next rollback |
| LAN | any of the above, if unbounded | every host the VM can route to, in either address family |
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

## Not bounded

Everything above is organised by control, which leaves the reader to assemble
the negative space themselves. Most will not. So, in one place, what a runner
built this way is *not* protected from. Each line has its argument somewhere
above or below; this list exists so nobody has to go looking to find out whether
there is one.

- **A job running hostile code.** That is what CI is. Nothing here tries to stop
  the code running.
- **Root on a privileged runner.** Granted by design, not defended. The tier
  exists to hand out the Docker socket.
- **Exfiltration, and command-and-control.** Egress to the internet is unbounded
  from the VM, deliberately. The confined tier's allowlist bounds it for a job,
  and an escape to root on the VM is precisely what leaves that behind.
- **The forge and the resolver.** Both are reachable from this VM on the ports
  listed, by anything on it. "No LAN access" is not literally true.
- **The forge credential the runner registers with.** It is on the box, and
  rollback restores it rather than rotating it.
- **What a merge lets through.** The allowlist is exactly as trustworthy as the
  merges are - see "What this tool assumes". A widened allowlist arrives through
  a reviewed-in-name-only pull request and this tool then serves it correctly.
- **Detection, and forensics.** Rollback destroys the evidence along with the
  intruder, and will happily rebuild a VM compromised through a route that is
  still open. It buys time, not diagnosis.
- **Inbound exposure.** One management address is the whole inbound list, and
  keeping it that way is yours. Nothing here checks it.
- **The hypervisor itself.** Out of scope, and it is the layer everything above
  is standing on.

## This page has a date on it

Every argument above is reasoning about a particular idea of what the adversary
can do, and that idea does not keep. The adversary here is a pull request whose
contents an agent wrote, and that description has not been getting more
reassuring.

Hardening designed against the agent of two years ago is not obviously adequate
against the agent of today, and the honest position is that nobody here can tell
you where the line is. What can be done is to re-read the reasoning on a
schedule rather than when something goes wrong.

**Quarterly**, matching dejima's own cadence.

What to check, rather than re-argue:

- the revisit conditions on each entry in "Rejected, with reasons". They are
  written as facts to look up, not judgements to re-make, so the review is cheap
  and has an answer;
- whether the forge has grown an approval gate, since the first rejected entry
  below is rejected on the grounds that there is no such feature rather than
  that it would be a weak control;
- whether the address families, ports and ranges named on the node still cover
  what a neighbour of this VM can be addressed by. IPv6 was missing from that
  list for as long as the list existed, and nothing failed in the meantime;
- whether the rollback is still running, which is the one control here that
  fails silently and completely - `proxmox/README.md` §4 has the check.

## Rejected, with reasons

Recorded so they are not re-proposed without new information.

**An approval gate before CI runs.** Not rejected as a weak control. There is
no forge feature that provides one.

[dejima's docs/ci.md](https://gitbox.branderson.io/dejima/dejima/src/branch/main/docs/ci.md#why-this-document-offers-no-approval-gate)
works through each version and each fails mechanically rather than in
practice: changing the trigger does not help, because the workflow file lives
in the tree the branch controls; dispatching by hand does not, because a token
that can open a pull request generally covers the dispatch endpoint too;
leaving the runner stopped does not, because a job that cannot land on your
runner lands on someone else's. Gitea's own approval requirement comes closest
and applies to pull requests **from forks**, which is precisely the case a
session pushing a branch to the same repository is not.

**Review cannot gate the run, because it happens after it.** The chain from a
session writing code to a runner executing it needs no operator action at any
step. By the time there is a diff for anyone to read, it has already run.

That is a statement about the run and about nothing else. **Review still gates
the merge, that is still the operator's job, and this repository depends on it
being done** - see [What this tool assumes](#what-this-tool-assumes). The two
are different controls at different points, and neither substitutes for the
other: bounding what a run can reach does not make a diff safe to merge
unread, and reading the diff does not stop the run that already happened.

**There is one control that works, and it sits upstream of everything here: do
not grant the session push access.** No push, no branch, no pull request, no
run.

That is not a workaround for CI, and reading it as one gets the order backwards.
It rests on a principle that holds whether or not CI exists anywhere - a session
that is not being used to push to a forge should not be able to push to it - and
the case that makes it concrete is an eager agent rather than a compromised one.

dejima states that in full, including what it costs the people on the other end
of an unsolicited pull request, at [GitHub push: blocked by default](https://gitbox.branderson.io/dejima/dejima/src/branch/main/docs/security.md#github-push-blocked-by-default-optional-opt-in).
The argument is not restated here, so that there is one copy of it to keep
right.

**How strongly it is enforced does belong here**, because it decides whether
this counts as a control at all. It is not a hook that a branch could route
around: GitHub's address ranges are allowlisted on port 443 only, so a session
can clone, fetch and call the API, and port 22 is simply unreachable. An SSH
push has no transport, whatever `git-push-guard.sh` does or does not catch.
`--allow-github-push` is what opens it, per launch.

Closing the CI chain follows from that principle. It is not the reason for it.

**This repository exists so that it is not the only answer.** Granting push
access should be a decision about how you want to work, not a decision to
accept unbounded code execution on your network. Bounding what the run can
reach is what leaves the first choice genuinely open.

**Inverting `policy_out` to deny-by-default with a port allowlist.** Rejected in
full in `proxmox/firewall.fw.template`, and the argument is not repeated here so
that it lives in one place. Briefly: it breaks ordinary software in ways that
present as network faults, and it buys nothing against an adversary assumed to
have root, who tunnels over 443 like everyone else.

**Mirroring the LAN DROPs into IPv6 instead of dropping the family.** Rejected
because the list cannot be written. There is no v6 range that means "private",
so the closest anyone can get is dropping `fc00::/7` and leaving the guest able
to reach every neighbour on the prefix the ISP delegated. A rule set that looks
symmetrical and covers nothing is worse than the blanket drop, because it reads
as handled by anyone reviewing it later.

Revisit if a privileged job ever genuinely needs IPv6 egress. The work then is a
pinhole for that destination, not dropping rule 10, because dropping it reopens
the LAN as well as the internet.

**Disabling IPv6 in the guest, with `net.ipv6.conf.all.disable_ipv6`.** Rejected
for the reason every node-side control here exists: it is a setting on a machine
this model assumes an attacker holds root on, and on the privileged tier that is
not even an assumption. Root sets it back.

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
