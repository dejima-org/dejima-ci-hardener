#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Keeps real network addresses out of the repository.
#
# Everything here is a runbook for building a machine on someone's LAN, so
# every example wants a plausible-looking address - and the easiest way to
# write one is to paste the address in front of you. That is how an operator's
# forge, resolver and VM addressing ended up in a public repository once
# already: not as a decision, but as three lines of an example that were
# already correct on the machine they were written on.
#
# This is the failure that cannot be caught by review, because a pasted address
# looks exactly like an invented one. So the check is mechanical: every IPv4
# literal must be on the list below, and adding to that list is a deliberate
# edit that says what the address is for.
#
# Prefer, in order:
#   - a placeholder, <forge-ip> or <iface>, which is this repository's idiom
#     and cannot be mistaken for a working value
#   - RFC 5737 documentation ranges: 192.0.2.0/24, 198.51.100.0/24,
#     203.0.113.0/24, which exist for exactly this and route nowhere
#   - an RFC1918 literal ONLY where the example has to be private to make
#     sense, as the job network's subnet does

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "no unexplained IPv4 literal is committed anywhere in the repository" {
    # Each entry is here because something needs it, not because it appeared.
    allowed=(
        0.0.0.0             # wildcard bind, sshd's ListenAddress
        127.0.0.1           # loopback, as a rejected upstream resolver
        127.0.0.53          # systemd-resolved's stub, named as NOT an answer
        255.255.255.255     # limited broadcast, in the DHCP rebind note
        169.254.169.254     # the cloud metadata address, named as a target

        10.0.0.0/8          # the four RFC1918 + link-local ranges the node
        172.16.0.0/12       # firewall drops. Ranges, not hosts: they name
        192.168.0.0/16      # every LAN rather than anybody's
        169.254.0.0/16

        10.89.0.0/24        # the suggested job network. Has to be private -
        10.89.0.1           # dnsmasq's stop-dns-rebind is keyed on the
                            # private ranges - so RFC 5737 will not do
        10.99.0.1           # the same, in test fixtures

        192.0.2.0/24        # the three RFC 5737 documentation ranges, named
        198.51.100.0/24     # in the guidance above as what to reach for
        203.0.113.0/24
        198.51.100.53       # RFC 5737 TEST-NET-2, as an upstream resolver
        203.0.113.1         # RFC 5737 TEST-NET-3, as a bridge gateway
        1.1.1.1             # a public resolver, as the off-list probe in
                            # ci-runner.bats. Has to be one that ANSWERS, or
                            # the negative checks pass with no network at all
        1.2.3.4             # obviously-fake, in an allowlist parser fixture
    )

    pattern="$(printf '%s\n' "${allowed[@]}" | sed 's/[.]/\\./g; s|/|\\/|g' | paste -sd'|' -)"

    # git ls-files: only what is committed, and never .git or a stray render
    # left in the working tree by a local run.
    found=$(cd "$REPO" && git ls-files -z \
        | xargs -0 grep -hoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?\b' 2>/dev/null \
        | sort -u | grep -vxE "$pattern" || true)

    if [ -n "$found" ]; then
        echo "IPv4 literals that are not on the allowlist in ${BASH_SOURCE[0]}:" >&2
        printf '  %s\n' $found >&2
        echo "" >&2
        echo "If one of these is a real address from a real network, replace it" >&2
        echo "with a <placeholder> or an RFC 5737 documentation address. If it" >&2
        echo "genuinely has to be there, add it to the list above with a comment" >&2
        echo "saying what it is for - the comment is the point of the list." >&2
        echo "" >&2
        echo "Where each one appears:" >&2
        for ip in $found; do
            ( cd "$REPO" && git grep -n -F -- "$ip" | sed 's/^/    /' >&2 ) || true
        done
        false
    fi
}
