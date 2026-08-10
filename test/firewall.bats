#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Rule order decides whether this firewall works at all, and proxmox/README.md
# calls it "the one thing here that is easy to get wrong" without anything
# checking it.
#
# Proxmox evaluates top to bottom and the first match wins, and every exception
# this file grants is to an address inside one of the ranges it drops. An
# exception below its DROP is dead, and dead in the quietest possible way: the
# VM boots, the console shows the rules present, and the runner simply cannot
# reach its forge.
#
# The console inserts new rules at the TOP of the list, so entering them in the
# documented order produces the reverse of it. Getting this wrong is therefore
# the default outcome of following the table, not an unusual mistake.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TPL="$REPO/proxmox/firewall.fw.template"
    [ -f "$TPL" ]
}

@test "every OUT ACCEPT comes before the first OUT DROP" {
    first_drop=$(grep -nE '^OUT DROP' "$TPL" | head -1 | cut -d: -f1)
    [ -n "$first_drop" ]
    last_accept=$(grep -nE '^OUT ACCEPT' "$TPL" | tail -1 | cut -d: -f1)
    [ -n "$last_accept" ]
    [ "$last_accept" -lt "$first_drop" ]
}

@test "all four dropped ranges are present" {
    for r in '10\.0\.0\.0/8' '172\.16\.0\.0/12' '192\.168\.0\.0/16' '169\.254\.0\.0/16'; do
        grep -qE "^OUT DROP -dest $r" "$TPL"
    done
}

@test "the forge and the resolver both have pinholes" {
    grep -qE '^OUT ACCEPT -dest __FORGE_IP__ -p tcp -dport 443' "$TPL"
    grep -qE '^OUT ACCEPT -dest __RESOLVER_IP__ -p udp -dport 53' "$TPL"
    grep -qE '^OUT ACCEPT -dest __RESOLVER_IP__ -p tcp -dport 53' "$TPL"
}

@test "policy is inbound DROP and outbound ACCEPT" {
    # Inverting policy_out is the tempting change this template argues against
    # at length. If someone acts on the temptation, this says so.
    grep -qE '^policy_in: DROP' "$TPL"
    grep -qE '^policy_out: ACCEPT' "$TPL"
}

@test "the DHCP pair is both halves or neither" {
    # Half the path renews nothing. The outbound rule is the tempting half to
    # add alone, because it is the one the DROPs visibly break, and on its own
    # the lease still never completes.
    out=$(grep -cE '^OUT ACCEPT -p udp -dport 67' "$TPL" || true)
    in=$(grep -cE '^IN ACCEPT -p udp -dport 68' "$TPL" || true)
    [ "$out" -eq "$in" ]
}

@test "no rule names a literal address outside the dropped ranges" {
    # addresses.bats catches leaks repository-wide; this catches a rule that
    # works on the network it was written on and silently on no other.
    run grep -nE '^(IN|OUT) (ACCEPT|DROP).*-(source|dest) [0-9]' "$TPL"
    for line in "${lines[@]}"; do
        case "$line" in
            *10.0.0.0/8*|*172.16.0.0/12*|*192.168.0.0/16*|*169.254.0.0/16*) ;;
            *) echo "rule names a literal address: $line"; false ;;
        esac
    done
}
