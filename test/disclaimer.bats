#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# The maturity disclaimer, pinned in all three places a reader can land.
#
# A repository that argues at length for its own security properties is exactly
# the one that has to say those properties are unreviewed. It is also the line
# most likely to be quietly dropped as a project starts to feel established -
# not by decision, but by a rewrite of a section that happened to contain it.
#
# Nothing else here would notice. Every other test in this suite would still
# pass on a repository that had lost it.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "every entry point says this is unreviewed early development" {
    for f in README.md SECURITY.md docs/threat-model.md; do
        grep -q 'reviewed by anyone else\|outside review' "$REPO/$f" || {
            echo "$f does not say the work is unreviewed" >&2
            false
        }
    done
    grep -q 'Not ready to be depended on' "$REPO/README.md"
    grep -q 'not proven software' "$REPO/SECURITY.md"
}
