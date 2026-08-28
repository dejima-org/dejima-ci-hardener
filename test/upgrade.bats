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

@test "a check that could not tell is recorded, not refused" {
    # check-lan exits 2 for "could not ask". Collapsing that into "not in force"
    # told the operator their console work was missing on the strength of a
    # check that never ran - wrong in the alarming direction, about the one
    # thing they cannot see for themselves.
    stub_check 2
    write_state tier=confined guest_version=2
    run_tool mark-node 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not tell"* ]]
    [[ "$output" != *"refusing to record"* ]]
    grep -q '^node_verified=no$' "$STATE_DIR/state"
}

@test "a check that says not-in-force is still refused" {
    # The distinction above must not have swallowed the real failure.
    stub_check 1
    write_state tier=confined guest_version=2
    run_tool mark-node 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to record"* ]]
}

@test "an unrecorded upgrade whose check passes is not reported as work to do" {
    # The record lives in the guest and a rollback takes it, while the console
    # work it described stays on the node. Without this, every rebuilt runner
    # says console work is outstanding that is in fact done - and an operator
    # who believes it goes and does it again.
    stub_check 0
    write_state tier=confined guest_version=2
    run_tool status
    [[ "$output" == *"NOT RECORDED, but its check passes"* ]]
    [[ "$output" != *"console work outstanding"* ]]
}

@test "an unrecorded upgrade whose check fails is reported as work to do" {
    stub_check 1
    write_state tier=confined guest_version=2
    run_tool status
    [[ "$output" == *"console work outstanding"* ]]
}

@test "the verify command is found beside the tool when it is not on PATH" {
    # The reported bug: the notes say to run from a checkout, and a PATH-only
    # lookup then could not find the program doing the looking.
    lonely="$BATS_TEST_TMPDIR/checkout"
    mkdir -p "$lonely/bin"
    cp "$TOOL" "$lonely/bin/dejima-ci-upgrade"
    ln -s "$REPO/upgrades" "$lonely/upgrades"
    write_state tier=confined guest_version=2
    # An empty PATH for the tool name specifically: nothing named
    # dejima-ci-upgrade is installed, exactly as on a runner at v1.
    CONF_DIR="$STATE_DIR" run "$lonely/bin/dejima-ci-upgrade" mark-node 2
    [[ "$output" != *"is not installed here"* ]]
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

@test "bootstrap installs the upgrade tool on the privileged tier" {
    # install.sh puts it on a confined host and does not run on a privileged
    # one. Without bootstrap doing it, the single tier whose ONLY boundary is
    # the node firewall is the single tier with no way to ask which node-side
    # versions it is missing - which is backwards.
    branch=$(awk '/elif \[ "\$ROLE" = privileged \]/,/^else$/' "$REPO/bin/dejima-ci-bootstrap")
    [ -n "$branch" ]
    printf '%s' "$branch" | grep -q 'bin/dejima-ci-upgrade' \
        || { echo "the privileged branch of bootstrap does not install dejima-ci-upgrade"; false; }
}

@test "bootstrap records the tier it has definitionally just built" {
    # The tool refuses to guess the tier, correctly. But this branch IS the
    # privileged path, so there is nothing to guess and no reason to make an
    # operator type it.
    branch=$(awk '/elif \[ "\$ROLE" = privileged \]/,/^else$/' "$REPO/bin/dejima-ci-bootstrap")
    printf '%s' "$branch" | grep -q 'tier=privileged' \
        || { echo "bootstrap does not record tier=privileged"; false; }
}

@test "the hand-install recipe writes where bootstrap writes" {
    # v2 gives a privileged operator three install commands, because install.sh
    # does not run on that tier and re-running bootstrap on a built machine
    # redoes runner setup. Those commands duplicate bootstrap's, so they can
    # drift from it - and a tool installed to the wrong path is a tool that is
    # not there, reported as "not installed here" three sections later.
    branch=$(awk '/elif \[ "\$ROLE" = privileged \]/,/^else$/' "$REPO/bin/dejima-ci-bootstrap")
    for dest in /usr/local/sbin/dejima-ci-upgrade /usr/local/share/dejima-ci/upgrades; do
        printf '%s' "$branch" | grep -qF "$dest" \
            || { echo "bootstrap no longer installs to $dest"; false; }
        grep -qF "$dest" "$REPO/upgrades/0002-ipv6-lan-boundary.md" \
            || { echo "v2's hand-install recipe no longer names $dest"; false; }
    done
}

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

@test "a note invoking the tool bare also says how it got onto the box" {
    # dejima-ci-upgrade arrives WITH a version, so on the machine being upgraded
    # it is not on $PATH until something installs it. A note that only ever says
    # `sudo dejima-ci-upgrade ...` hands the operator a command that cannot run
    # on the host it was written for - which is exactly what v2 did, and what
    # sent someone to read an error about the tool being unable to find itself.
    #
    # Not "never invoke it bare": a note may legitimately show the bare form
    # after an install.sh step, and v2 now shows both, for the two situations an
    # operator can be in. What it may not do is show only the bare form with no
    # account of where the program came from.
    for f in "$REPO"/upgrades/0*.md; do
        grep -qE '^[[:space:]]*(sudo )?dejima-ci-upgrade ' "$f" || continue
        grep -qE '(\./bin/dejima-ci-upgrade|install\.sh)' "$f" \
            || { echo "$f: invokes the tool bare and never says how it got there"; false; }
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
