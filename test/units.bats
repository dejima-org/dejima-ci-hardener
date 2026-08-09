#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# The systemd units, checked against where the installer actually puts things.
#
# These exist because the failure they guard has no symptom worth the name. A
# unit naming a program that is not there fails with 203/EXEC on every start,
# and for a timer that means the allowlist silently stops being refreshed: no
# error anyone sees, no change to the file, and a host that looks configured
# while merging a domain to main does nothing at all.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
}

@test "no unit hard-codes a path to a program the installer places" {
    # The path belongs to install.sh. Written down a second time it can only
    # agree by luck, and it did not.
    run grep -nE '^Exec(Start|Stop)=/(usr|opt|bin|sbin)' "$REPO"/systemd/*.service
    [ "$status" -ne 0 ]
}

@test "every unit's ExecStart resolves to the directory the installer uses" {
    bin=$(sed -n 's|^BIN_DIR=${BIN_DIR:-\(.*\)}|\1|p' "$REPO/install.sh")
    [ -n "$bin" ]
    for u in "$REPO"/systemd/*.service; do
        exe=$(sed -n 's|^ExecStart=\([^ ]*\).*|\1|p' "$u" | head -1)
        [ -n "$exe" ]
        # After substitution it must name a program this repository ships.
        resolved="${exe/@@BIN_DIR@@/$bin}"
        [ "$resolved" != "$exe" ] || { echo "$u: ExecStart is not templated: $exe"; false; }
        prog="${resolved##*/}"
        [ -f "$REPO/bin/$prog" ] || { echo "$u: names $prog, which bin/ does not ship"; false; }
    done
}

@test "install.sh substitutes the marker rather than copying it through" {
    grep -q '@@BIN_DIR@@' "$REPO/install.sh"
    # And refuses to finish if what it wrote is not executable.
    grep -q 'which is not executable' "$REPO/install.sh"
}
