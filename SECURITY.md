# Security policy

## What dejima-ci-hardener claims

It reduces what a job can reach. It does not make a host safe.

A confined runner is given no Docker socket, its own bridge, and a
deny-by-default egress allowlist. A privileged runner is given the socket and
the host network deliberately, and its containment is the hypervisor firewall
and a scheduled rollback, not anything this program does inside the guest.
Neither tier holds against an attacker who is already root on the box.

The README's [How it fails](README.md#how-it-fails) section covers this in
detail.

## Reporting a vulnerability

Email **dejima@branderson.io**. Please do not open a public issue for a
vulnerability; the tracker is public, and a report there is a disclosure.

Useful things to include:

1. what an attacker gets;
2. the steps to reproduce it;
3. which tier it applies to: confined, privileged, or both;
4. the commit you tested.

## The rest of the policy

What is promised in return, the support position, supported versions and
warranty are set once for the whole organisation and are not restated here:

https://gitbox.branderson.io/dejima/dejima/src/branch/main/SECURITY.md
