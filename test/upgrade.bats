#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Three things this tool must not do:
#
#   - report "up to date" about versions it has never heard of;
#   - record an operator's claim about the hypervisor that the machine in front
#     of it already contradicts;
#   - let a guest-side upgrade be presented as one step, when on a runner the
#     scheduled rollback undoes anything that was not baked into the snapshot.
#
# The third is the one with no equivalent in the sister project.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TOOL="$REPO/bin/dejima-ci-upgrade"
    STATE_DIR="$BATS_TEST_TMPDIR/etc"
    STUB_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STATE_DIR" "$STUB_DIR"
}

run_tool() { CONF_DIR="$STATE_DIR" PATH="$STUB_DIR:$PATH" run "$TOOL" "$@"; }
write_state() { printf '%s\n' "$@" > "$STATE_DIR/state"; }

stub_check() {
    printf '#!/bin/sh\nexit %s\n' "$1" > "$STUB_DIR/dejima-ci-upgrade"
    chmod +x "$STUB_DIR/dejima-ci-upgrade"
}

# --- the tier is not guessed ------------------------------------------------

@test "no recorded tier is refused rather than detected" {
    # An absent config identifies a privileged host correctly and also
    # identifies a confined one whose install.sh has not run. Guessing selects a
    # different set of upgrades.
    run_tool status --no-verify
    [ "$status" -eq 2 ]
    [[ "$output" == *"no tier recorded"* ]]
}

@test "set-tier refuses a word that is not one of the two" {
    run_tool set-tier runtime
    [ "$status" -ne 0 ]
    [[ "$output" == *"confined"* ]]
}

@test "the privileged tier reports no guest half rather than a missing one" {
    # That tier installs nothing in the guest by design. Unset is the correct
    # reading, not a gap.
    write_state tier=privileged node_version=2 node_asserted=2026-08-25 node_verified=yes
    run_tool status --no-verify
    [[ "$output" == *"guest   n/a"* ]]
    [[ "$output" != *"guest   unrecorded"* ]]
}

@test "a guest-layer upgrade is never listed as outstanding on the privileged tier" {
    write_state tier=privileged node_version=2
    run_tool status --no-verify
    [[ "$output" != *"rollback-sensitive"* ]]
}

# --- knowing where you are --------------------------------------------------

@test "a host with a tier and nothing else is not assumed to be v1" {
    write_state tier=confined
    run_tool status --no-verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"predates version tracking"* ]]
    [[ "$output" == *"NOT assumed to be v1"* ]]
}

@test "an up-to-date confined runner reports nothing outstanding" {
    write_state tier=confined guest_version=2 node_version=2 node_asserted=2026-08-25 node_verified=yes
    run_tool status --no-verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing."* ]]
}

@test "v2 needs node work only, so it must not ask for a re-snapshot" {
    # The cheap kind of upgrade. Everything it changes lives on the hypervisor,
    # where no rollback reaches it. Reporting otherwise would train an operator
    # to ignore the sequence when it does matter.
    write_state tier=confined guest_version=2 node_version=1 node_asserted=2026-06-01
    run_tool status --no-verify
    [[ "$output" == *"console work outstanding"* ]]
    [[ "$output" != *"not one step"* ]]
}

@test "a guest behind its node is named as a rollback that outran an upgrade" {
    write_state tier=confined guest_version=1 node_version=2 node_asserted=2026-08-25
    run_tool status --no-verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"guest is behind the node"* ]]
    [[ "$output" == *"never baked into the snapshot"* ]]
}

@test "the installed copy admits it cannot see newer versions" {
    share="$BATS_TEST_TMPDIR/share"
    mkdir -p "$share/upgrades" "$BATS_TEST_TMPDIR/sbin"
    cp "$REPO"/upgrades/0001-*.md "$share/upgrades/"
    cp "$TOOL" "$BATS_TEST_TMPDIR/sbin/dejima-ci-upgrade"
    write_state tier=confined guest_version=1 node_version=1
    CONF_DIR="$STATE_DIR" SHARE_DIR="$share" \
        run "$BATS_TEST_TMPDIR/sbin/dejima-ci-upgrade" status --no-verify
    [[ "$output" == *"installed copy"* ]]
}

@test "with no notes reachable it refuses rather than reporting a clean run" {
    lonely="$BATS_TEST_TMPDIR/lonely"
    mkdir -p "$lonely"
    cp "$TOOL" "$lonely/dejima-ci-upgrade"
    write_state tier=confined guest_version=1 node_version=1
    CONF_DIR="$STATE_DIR" SHARE_DIR="$BATS_TEST_TMPDIR/absent" \
        run "$lonely/dejima-ci-upgrade" status --no-verify
    [ "$status" -eq 2 ]
    [[ "$output" == *"no upgrade notes found"* ]]
}

# --- not recording a claim the machine contradicts --------------------------

@test "mark-node refuses when the check for that upgrade fails" {
    stub_check 1
    write_state tier=confined guest_version=2
    run_tool mark-node 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to record"* ]]
    ! grep -q '^node_version=' "$STATE_DIR/state"
}

@test "mark-node records when the check passes" {
    stub_check 0
    write_state tier=confined guest_version=2
    run_tool mark-node 2
    [ "$status" -eq 0 ]
    grep -q '^node_version=2$' "$STATE_DIR/state"
    grep -q '^node_verified=yes$' "$STATE_DIR/state"
}

@test "--force records the claim but marks it unverified" {
    stub_check 1
    write_state tier=confined guest_version=2
    run_tool mark-node 2 --force
    [ "$status" -eq 0 ]
    grep -q '^node_verified=no$' "$STATE_DIR/state"
}

@test "status contradicts a recorded claim the machine no longer supports" {
    stub_check 1
    write_state tier=confined guest_version=2 node_version=2 node_asserted=2026-06-01 node_verified=yes
    run_tool status
    [ "$status" -ne 0 ]
    [[ "$output" == *FAILED* ]]
}

# --- check-lan --------------------------------------------------------------

@test "our own reply to our own multicast is not a neighbour" {
    source "$TOOL"
    out='64 bytes from fe80::1%eth0: icmp_seq=1 ttl=64 time=0.052 ms'
    run replies_from_others "$out" 'fe80::1'
    [ "$output" = 0 ]
}

@test "a neighbour's reply alongside our own is counted" {
    source "$TOOL"
    out='64 bytes from fe80::1%eth0: icmp_seq=1 ttl=64 time=0.052 ms
64 bytes from fe80::99%eth0: icmp_seq=1 ttl=64 time=1.21 ms (DUP!)'
    run replies_from_others "$out" 'fe80::1'
    [ "$output" = 1 ]
}

@test "a probe that could not run is unknown, not a pass" {
    # Nobody answered because nobody was asked. Exit 2, distinct from the 1 that
    # means something answered.
    source "$TOOL"
    routable_v6_addr() { printf ''; }
    neighbour_replies() { return 1; }
    run cmd_check_lan
    [ "$status" -eq 2 ]
    [[ "$output" == *"Not a pass"* ]]
}

@test "a routable v6 address fails without needing the probe" {
    source "$TOOL"
    routable_v6_addr() { printf '2001:db8::5/64\n'; }
    run cmd_check_lan
    [ "$status" -eq 1 ]
    [[ "$output" == *FAIL* ]]
}

@test "a silent segment passes" {
    source "$TOOL"
    routable_v6_addr() { printf ''; }
    neighbour_replies() { printf '0\n'; }
    run cmd_check_lan
    [ "$status" -eq 0 ]
    [[ "$output" == *PASS* ]]
}

# --- the notes themselves ---------------------------------------------------

@test "every version from 1 to VERSION has an upgrade note" {
    newest=$(tr -d '[:space:]' < "$REPO/VERSION")
    for v in $(seq 1 "$newest"); do
        ls "$REPO/upgrades/$(printf '%04d' "$v")"-*.md >/dev/null 2>&1 \
            || { echo "no upgrade note for v$v"; false; }
    done
}

@test "every note's version field matches its filename" {
    for f in "$REPO"/upgrades/0*.md; do
        from_name=$(basename "$f" | sed 's/^0*\([0-9][0-9]*\)-.*/\1/')
        from_head=$(sed -n '/^---$/,/^---$/p' "$f" | sed -n 's/^version: //p' | head -1)
        [ "$from_name" = "$from_head" ] \
            || { echo "$f: filename says $from_name, header says $from_head"; false; }
    done
}

@test "every note declares the keys the tool reads, including tiers" {
    for f in "$REPO"/upgrades/0*.md; do
        for k in version title layers tiers snapshot; do
            sed -n '/^---$/,/^---$/p' "$f" | grep -q "^$k: " \
                || { echo "$f: no '$k' in the header"; false; }
        done
    done
}

@test "a note naming a guest layer also requires a snapshot" {
    # On a runner these are the same statement: a guest change not baked into
    # the snapshot is undone at the next rollback. A note claiming otherwise
    # would be wrong in the direction that loses the change silently.
    for f in "$REPO"/upgrades/0*.md; do
        head=$(sed -n '/^---$/,/^---$/p' "$f")
        case "$(printf '%s' "$head" | sed -n 's/^layers: //p')" in
            *guest*)
                [ "$(printf '%s' "$head" | sed -n 's/^snapshot: //p')" = required ] \
                    || { echo "$f: touches the guest but does not require a snapshot"; false; } ;;
        esac
    done
}

@test "a note with no guest step does not invoke the tool as if it were installed" {
    # dejima-ci-upgrade arrives WITH a version. A note whose layers do not
    # include 'guest' installs nothing, so on the machine being upgraded the
    # tool is not on $PATH and will not be put there by that note - it has to be
    # run from a checkout. Telling an operator otherwise gives them a command
    # that cannot work on the host it was written for.
    for f in "$REPO"/upgrades/0*.md; do
        layers=$(sed -n '/^---$/,/^---$/p' "$f" | sed -n 's/^layers: //p')
        case " $layers " in *" guest "*) continue ;; esac
        ! grep -qE '^[[:space:]]*(sudo )?dejima-ci-upgrade ' "$f" \
            || { echo "$f: no guest step installs it, so commands must use ./bin/dejima-ci-upgrade"; false; }
    done
}

@test "VERSION is a bare integer, since the scheme has no minor part" {
    run cat "$REPO/VERSION"
    [[ "$output" =~ ^[0-9]+$ ]]
}

@test "the newest note matches VERSION, so a bump cannot be half-done" {
    newest_note=$(ls "$REPO"/upgrades/0*.md | sed -n 's/.*\/0*\([0-9][0-9]*\)-.*/\1/p' | sort -n | tail -1)
    [ "$newest_note" = "$(tr -d '[:space:]' < "$REPO/VERSION")" ]
}
