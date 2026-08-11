#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Every relative link in the documentation resolves, and every anchor names a
# heading that exists.
#
# This repository is mostly prose, and the prose is the product: the runbook is
# the thing being shipped, not a description of it. A link that goes nowhere is
# therefore a defect in the deliverable rather than a cosmetic problem.
#
# It is also the kind of defect review does not catch. A link reads as correct
# whether or not it resolves, and the ones most likely to be wrong are the ones
# written before their target exists - which is every forward reference in a
# runbook written in the order a reader will follow it. The sister project had
# four dangling at once while it was being built, each perfectly plausible on
# the page, and this repository has more documentation than that one does.
#
# Anchors are the harder half and the reason this is mechanical. A heading
# renamed for clarity silently orphans every link to it, and nothing about
# either file looks different afterwards.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# Gitea and GitHub both slugify a heading by lowercasing it, dropping anything
# that is not alphanumeric, space or dash, then turning spaces into dashes.
anchors_of() {
    grep -oE '^#+ .*' "$1" \
        | sed 's/^#* //; s/[^a-zA-Z0-9 -]//g; s/ /-/g' \
        | tr 'A-Z' 'a-z'
}

@test "every relative link points at a file that exists" {
    fails=""
    while IFS= read -r f; do
        while IFS= read -r l; do
            case "$l" in http*|mailto:*|"") continue ;; esac
            target="${l%%#*}"
            [ -n "$target" ] || continue    # a bare #anchor is same-file
            path="$(dirname "$f")/$target"
            [ -e "$path" ] || fails="$fails\n  $f -> $l"
        done < <(grep -oE '\]\([^)]+\)' "$f" | sed 's/](//; s/)$//')
    done < <(cd "$REPO" && git ls-files '*.md')

    if [ -n "$fails" ]; then
        printf 'links whose target does not exist:%b\n' "$fails" >&2
        false
    fi
}

@test "every anchor names a heading that exists in the file it points at" {
    fails=""
    while IFS= read -r f; do
        while IFS= read -r l; do
            case "$l" in http*|mailto:*|"") continue ;; esac
            case "$l" in *#*) ;; *) continue ;; esac
            target="${l%%#*}"; anchor="${l#*#}"
            if [ -z "$target" ]; then path="$f"; else path="$(dirname "$f")/$target"; fi
            [ -e "$path" ] || continue      # reported by the test above
            anchors_of "$path" | grep -qx "$anchor" \
                || fails="$fails\n  $f -> $l"
        done < <(grep -oE '\]\([^)]+\)' "$f" | sed 's/](//; s/)$//')
    done < <(cd "$REPO" && git ls-files '*.md')

    if [ -n "$fails" ]; then
        printf 'anchors naming no heading:%b\n' "$fails" >&2
        echo "" >&2
        echo "A heading renamed for clarity orphans every link to it, and" >&2
        echo "nothing about either file looks different afterwards." >&2
        false
    fi
}

@test "every image the README references is a file this repository ships" {
    # Both syntaxes and both formats. The wordmark is an <img> tag and a png;
    # the badge is markdown image syntax and an svg. A test written for only
    # the first pair would not have seen the second at all.
    found=0
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        case "$src" in http*) continue ;; esac
        found=$((found + 1))
        [ -f "$REPO/$src" ] || { echo "README references missing image: $src"; false; }
    done < <(grep -ohE 'src="[^"]+\.(png|svg)"|\]\([^)]+\.(png|svg)\)' "$REPO/README.md" \
             | sed 's/^src="//; s/"$//; s/^](//; s/)$//')
    [ "$found" -ge 2 ] || { echo "expected at least the wordmark and the badge"; false; }

    # Both wordmark modes ship, so a mirror on a light-themed host changes one
    # line rather than needing a file it does not have.
    [ -f "$REPO/assets/dejima-wordmark-darkmode.png" ]
    [ -f "$REPO/assets/dejima-wordmark-lightmode.png" ]
}

@test "the guard fails when a link is broken, rather than passing quietly" {
    # A link checker nobody has watched fail is a link checker nobody should
    # trust. Build a file with one bad link of each kind and confirm both
    # tests above would have caught them.
    tmp="$BATS_TEST_TMPDIR/broken.md"
    printf '# Heading\n\n[gone](does-not-exist.md)\n[orphan](#no-such-heading)\n' > "$tmp"

    run bash -c "grep -oE '\]\([^)]+\)' '$tmp' | sed 's/](//; s/)\$//'"
    [ "$status" -eq 0 ]
    [[ "$output" == *does-not-exist.md* ]]
    [[ "$output" == *"#no-such-heading"* ]]

    # The file target does not exist.
    [ ! -e "$(dirname "$tmp")/does-not-exist.md" ]
    # The anchor names no heading in its own file.
    run anchors_of "$tmp"
    [[ "$output" != *no-such-heading* ]]
}
