#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Every ```sh block in the documentation parses as shell.
#
# The runbooks are the product here, and a command in one of them is not an
# illustration - it is something an operator pastes into a root shell on a
# hypervisor while following the page. A block that does not parse is a defect
# in the deliverable, exactly as a dangling link is.
#
# This exists because of a specific near-miss. Restructuring prose around a
# fenced block turned a `\` line continuation into `\\`, which is an escaped
# backslash rather than a continuation. The rendered page looked right, the diff
# looked like prose, and the helper function on the other side of it would have
# failed for anyone who pasted it - with an error naming the line after the one
# that was wrong.
#
# Nothing else here would have caught it. links.bats reads markdown structure,
# addresses.bats reads for leaked literals, and neither looks inside a code
# fence. Review does not catch it either: a backslash at the end of a line is
# not something a reader counts.
#
# WHAT THIS DOES NOT CHECK is whether a command is correct, whether its flags
# exist, or whether it does what the surrounding prose claims. `bash -n` parses
# and does not execute - which is the only safe thing to do with a file full of
# `sudo iptables` and `rm`, and is why this is a syntax check rather than a
# test of the documentation's truth.
#
# PLACEHOLDERS ARE SUBSTITUTED BEFORE PARSING, and that is not a convenience.
# `<name>` is this repository's placeholder idiom, not shell, and shell reads it
# as redirection - so whether a block parses would otherwise depend on how many
# angle brackets happened to land on a line. `try <forge-ip> 443` parses by
# accident, as two redirects; `ssh <you>@<vm-ip>` does not, because the trailing
# `>` has nothing after it. Testing that distinction would be testing nothing
# anyone cares about, and would push the docs towards whichever placeholder
# spelling appeased the parser.
#
# The pattern requires a letter after the `<`, which keeps `3<>/dev/tcp/...`
# and `<<EOF` intact - both real shell, and both things a naive substitution
# would quietly corrupt into a passing test.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "every fenced sh block parses as shell" {
    work="$BATS_TEST_TMPDIR/snippets"
    mkdir -p "$work"

    # Extracted to files rather than piped, so bash -n reports a line number
    # inside the block and the .loc file turns it back into a place in the docs.
    while IFS= read -r f; do
        safe="$(printf '%s' "$f" | tr '/.' '__')"
        awk -v dir="$work" -v pfx="$safe" -v file="$f" '
            /^```sh$/ {
                inblock = 1; n++
                out = dir "/" pfx "_" n ".sh"
                print file ":" NR > (out ".loc"); close(out ".loc")
                next
            }
            /^```$/ { if (inblock) { close(out); inblock = 0 } ; next }
            inblock { print >> out }
        ' "$REPO/$f"
    done < <(cd "$REPO" && git ls-files '*.md')

    checked=0
    fails=""
    for snippet in "$work"/*.sh; do
        [ -e "$snippet" ] || continue
        checked=$((checked + 1))
        sed -i -E 's/<[a-zA-Z][^<>]*>/PLACEHOLDER/g' "$snippet"
        if ! err="$(bash -n "$snippet" 2>&1)"; then
            fails="$fails\n  $(cat "$snippet.loc")\n$(printf '%s' "$err" | sed 's/^/      /')"
        fi
    done

    # A pass that checked nothing is the failure this suite exists to avoid, and
    # an extractor that silently stops matching is exactly how it would happen.
    [ "$checked" -gt 0 ] || { echo "no sh blocks found - the extractor is broken, not the docs" >&2; false; }

    if [ -n "$fails" ]; then
        printf 'fenced sh blocks that do not parse:%b\n' "$fails" >&2
        false
    fi
}

@test "the guard fails when a block is broken, rather than passing quietly" {
    # The same shape as links.bats's own self-check. A guard that cannot fail is
    # indistinguishable from one that always passes, and this one runs over
    # files nobody expects to break.
    printf 'x() { echo a \\\\\n  && echo b; }\n' > "$BATS_TEST_TMPDIR/broken.sh"
    run bash -n "$BATS_TEST_TMPDIR/broken.sh"
    [ "$status" -ne 0 ]
}
