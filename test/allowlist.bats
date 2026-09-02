#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Drives bin/dejima-ci-allowlist against a stubbed curl and dnsmasq, so the
# properties being checked are the ones that decide whether this program is
# worth running: where it reads from, and which failures leave the previous
# allowlist alone.

setup() {
    T="$(mktemp -d)"
    BIN="${BATS_TEST_DIRNAME}/../bin/dejima-ci-allowlist"
    mkdir -p "$T/stub" "$T/out"

    # curl stub: prints whatever the fixture for this repo holds and reports
    # the status the test asked for. Records the URL it was given, since half
    # of what matters here is the ref in that URL.
    cat > "$T/stub/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        # Recorded so a test can assert on what actually went over the wire,
        # which is the only place token mangling is visible.
        -H) printf '%s\n' "$2" >> "$STUB_DIR/last-headers"; shift ;;
        http*) url="$1" ;;
    esac
    shift
done
echo "$url" >> "$STUB_URLS"
repo=$(sed -E 's#.*/repos/([^/]+/[^/]+)/raw.*#\1#' <<< "$url")
status=$(cat "$STUB_DIR/$repo.status" 2>/dev/null || echo 200)
[ -f "$STUB_DIR/$repo.body" ] && cat "$STUB_DIR/$repo.body" > "$out" || : > "$out"
echo -n "$status"
EOF

    # dnsmasq stub: --test passes unless a test says otherwise.
    cat > "$T/stub/dnsmasq" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_DNSMASQ_FAIL:-}" ] && exit 1
exit 0
EOF
    chmod +x "$T/stub/curl" "$T/stub/dnsmasq"

    export PATH="$T/stub:$PATH"
    export STUB_DIR="$T/fixtures" STUB_URLS="$T/urls"
    mkdir -p "$STUB_DIR"

    echo token > "$T/token"
    echo "owner/repo" > "$T/repos"
    : > "$T/base"
    # A correctly configured host: a repository that declares names has a set of
    # its own. Without one the render refuses, which is its own test rather than
    # the state every other test starts from.
    echo "owner/repo 1" > "$T/pools"

    cat > "$T/config" <<EOF
forge_api = https://gitea.example.com/api/v1
token_file = $T/token
repos_file = $T/repos
pools_file = $T/pools
base_file = $T/base
upstream = 198.51.100.53
out = $T/out/ci-allow.conf
reload = true
EOF
}

teardown() { rm -rf "$T"; }

run_tool() { run "$BIN" "$@" --config "$T/config"; }

@test "renders one server= line per declared domain" {
    mkdir -p "$STUB_DIR/owner"
    printf 'example.com\ndeb.debian.org\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]
    grep -q '^server=/example.com/198.51.100.53$' "$T/out/ci-allow.conf"
    grep -q '^server=/deb.debian.org/198.51.100.53$' "$T/out/ci-allow.conf"
}

@test "reads main by default, and the ref is in the request" {
    mkdir -p "$STUB_DIR/owner"; echo example.com > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]
    grep -q 'ref=main' "$T/urls"
}

# The whole point of the program. A ref a pull request can write is not a
# source of truth, so this is worth a test rather than a comment.
@test "the ref is configurable but defaults to the operator's branch" {
    mkdir -p "$STUB_DIR/owner"; echo example.com > "$STUB_DIR/owner/repo.body"
    echo "ref = release" >> "$T/config"
    run_tool render
    grep -q 'ref=release' "$T/urls"
}

@test "a repository with no declaration is skipped, not fatal" {
    mkdir -p "$STUB_DIR/owner"
    echo 404 > "$STUB_DIR/owner/repo.status"
    echo example.com > "$T/base"
    run_tool render
    [ "$status" -eq 0 ]
    grep -q '^server=/example.com/' "$T/out/ci-allow.conf"
}

@test "an unexpected HTTP status is fatal and installs nothing" {
    mkdir -p "$STUB_DIR/owner"
    echo 500 > "$STUB_DIR/owner/repo.status"
    echo example.com > "$T/base"
    run_tool render
    [ "$status" -ne 0 ]
    [ ! -f "$T/out/ci-allow.conf" ]
    [[ "$output" == *"HTTP 500"* ]]
}

@test "a rejected token says so, rather than reporting an HTTP number" {
    # 401 is the one an operator actually meets, and "unexpected HTTP 401" sends
    # nobody to the token. It has to name the file and say that a present-but-
    # wrong token is what this looks like, because an empty one is refused
    # earlier with a different message entirely.
    mkdir -p "$STUB_DIR/owner"
    echo 401 > "$STUB_DIR/owner/repo.status"
    echo example.com > "$T/base"
    run_tool render
    [ "$status" -ne 0 ]
    [ ! -f "$T/out/ci-allow.conf" ]
    [[ "$output" == *"rejected the token"* ]]
    [[ "$output" == *"$T/token"* ]]
}

@test "a token refused permission is not confused with one refused outright" {
    # 403 authenticates and cannot read. Telling someone to replace a token
    # that is fine, when the answer is a scope they did not grant, costs them
    # the one thing the message was supposed to save.
    mkdir -p "$STUB_DIR/owner"
    echo 403 > "$STUB_DIR/owner/repo.status"
    echo example.com > "$T/base"
    run_tool render
    [ "$status" -ne 0 ]
    [[ "$output" == *"refused the read"* ]]
    [[ "$output" == *"scope"* ]]
    [[ "$output" != *"rejected the token"* ]]
}

@test "surrounding whitespace in the token file never reaches the forge" {
    # Command substitution strips trailing newlines and nothing else, so a
    # trailing space or a carriage return survives into the Authorization
    # header and the forge rejects it - while the file still looks correct to
    # anyone who cats it.
    printf 'tok123 \r\n' > "$T/token"
    echo example.com > "$T/base"
    run_tool render
    [ "$status" -eq 0 ]
    grep -q 'Authorization: token tok123$' "$STUB_DIR/last-headers"
}

@test "a renamed repository is named as such, and not followed" {
    # Gitea 301s the old path after a rename or a transfer. Following it would
    # mean reading the allowlist from whichever repository the forge points at
    # now, which is the one thing this program must not do - the whole premise
    # is that the list comes from a branch of a repository the operator named.
    mkdir -p "$STUB_DIR/owner"
    echo 301 > "$STUB_DIR/owner/repo.status"
    echo example.com > "$T/base"
    run_tool render
    [ "$status" -ne 0 ]
    [ ! -f "$T/out/ci-allow.conf" ]
    [[ "$output" == *"renamed or moved"* ]]
    [[ "$output" == *"$T/repos"* ]]
    [[ "$output" != *"unexpected HTTP"* ]]
}

@test "an empty collection is refused rather than installed" {
    mkdir -p "$STUB_DIR/owner"; : > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -ne 0 ]
    [ ! -f "$T/out/ci-allow.conf" ]
    [[ "$output" == *"empty allowlist"* ]]
}

@test "a malformed entry is refused, and refused loudly" {
    mkdir -p "$STUB_DIR/owner"
    printf 'example.com\nnot a domain\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -ne 0 ]
    [ ! -f "$T/out/ci-allow.conf" ]
    [[ "$output" == *"malformed"* ]]
}

# An entry that smuggles a second directive past the renderer would turn a
# declaration file into resolver configuration.
@test "an entry carrying a newline or a directive cannot reach the output" {
    mkdir -p "$STUB_DIR/owner"
    printf 'example.com\nevil.com/1.2.3.4\naddr=/x/1.2.3.4\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -ne 0 ]
    [ ! -f "$T/out/ci-allow.conf" ]
}

@test "an existing allowlist survives a failed run" {
    mkdir -p "$STUB_DIR/owner"; echo example.com > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]
    cp "$T/out/ci-allow.conf" "$T/before"

    echo 500 > "$STUB_DIR/owner/repo.status"
    run_tool render
    [ "$status" -ne 0 ]
    cmp "$T/before" "$T/out/ci-allow.conf"
}

@test "a config that fails dnsmasq --test is not installed" {
    mkdir -p "$STUB_DIR/owner"; echo example.com > "$STUB_DIR/owner/repo.body"
    STUB_DNSMASQ_FAIL=1 run_tool render
    [ "$status" -ne 0 ]
    [ ! -f "$T/out/ci-allow.conf" ]
}

@test "an unchanged allowlist is not reinstalled or reloaded" {
    mkdir -p "$STUB_DIR/owner"; echo example.com > "$STUB_DIR/owner/repo.body"
    run_tool render
    before=$(stat -c %Y "$T/out/ci-allow.conf")
    sleep 1
    run_tool render
    [ "$status" -eq 0 ]
    [ "$(stat -c %Y "$T/out/ci-allow.conf")" -eq "$before" ]
}

# The config file names a token path and sits on a CI host. Sourcing it would
# make an unexpected line executable.
@test "the config is parsed, not sourced" {
    echo 'upstream = $(touch '"$T"'/pwned)' >> "$T/config"
    mkdir -p "$STUB_DIR/owner"; echo example.com > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ ! -f "$T/pwned" ]
}

@test "an unknown config key is a hard error, not a silent typo" {
    echo 'upstreem = 198.51.100.53' >> "$T/config"
    run_tool render
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown key"* ]]
}

@test "a first install reports what it would install, not a diff error" {
    # The allowlist does not exist yet on a first run, which is the ordinary
    # case and not a fault. Handing diff a path that is not there prints its
    # complaint instead of the answer, on the one run where the operator is
    # least able to tell the difference.
    mkdir -p "$STUB_DIR/owner"
    printf 'example.com\ndeb.debian.org\n' > "$STUB_DIR/owner/repo.body"
    [ ! -f "$T/out/ci-allow.conf" ]
    run_tool check
    [ "$status" -eq 1 ]
    [[ "$output" == *"would install"* ]]
    [[ "$output" == *"2 names"* ]]
    [[ "$output" != *"No such file"* ]]
    [ ! -f "$T/out/ci-allow.conf" ]
}

@test "check reports a pending change without installing it" {
    mkdir -p "$STUB_DIR/owner"; echo example.com > "$STUB_DIR/owner/repo.body"
    run_tool check
    [ "$status" -eq 1 ]
    [ ! -f "$T/out/ci-allow.conf" ]
}

# --- preflight and exit codes ------------------------------------------------
#
# The first version reported configuration problems one at a time, and the
# worst of them not at all: a missing token_file surfaced as bash's own "No
# such file or directory" with a line number, then "empty token" (it was
# absent, not empty), then "collection failed" - three messages, none naming
# the setting that pointed there.

@test "a missing token file names the setting, the path, and what belongs there" {
    rm -f "$T/token"
    run_tool check
    [ "$status" -eq 2 ]
    [[ "$output" == *"token_file points at $T/token"* ]]
    [[ "$output" == *"does not exist"* ]]
    # Which kind of token, not just that one is wanted. A forge hands out two
    # and this tool asks for both; naming only "a token" is how the wrong one
    # ends up in the file, where it authenticates against nothing and the only
    # symptom is a 401 from an unrelated-looking command.
    [[ "$output" == *"API token"* ]]
    [[ "$output" == *"registration token"* ]]
}

@test "every configuration problem is reported in one run, not one per run" {
    rm -f "$T/token" "$T/repos"
    sed -i 's|^upstream = .*|upstream =|' "$T/config"
    run_tool check
    [ "$status" -eq 2 ]
    [[ "$output" == *"token_file"* ]]
    [[ "$output" == *"repos_file"* ]]
    [[ "$output" == *"upstream"* ]]
    [[ "$output" == *"3 problem(s)"* ]]
}

# The upstream setting is the one an operator is most likely to fill in wrongly,
# so its hint has to say what it is rather than only that it is missing.
@test "the upstream hint says which resolver is meant" {
    sed -i 's|^upstream = .*|upstream =|' "$T/config"
    run_tool check
    [[ "$output" == *"forwards ALLOWED queries"* ]]
    [[ "$output" == *"not the bridge gateway"* ]]
}

@test "an empty token file is reported as empty, not as missing" {
    : > "$T/token"
    run_tool check
    [ "$status" -eq 2 ]
    [[ "$output" == *"is empty"* ]]
}

# 1 means "there is a pending change" and is an ordinary answer; everything
# that is a fault has to be distinguishable from it, or a timer's alerting
# cannot tell "the allowlist moved" from "the forge is unreachable".
@test "a fault exits 2 and a pending change exits 1" {
    mkdir -p "$STUB_DIR/owner"; echo example.com > "$STUB_DIR/owner/repo.body"
    run_tool check
    [ "$status" -eq 1 ]

    echo 500 > "$STUB_DIR/owner/repo.status"
    run_tool check
    [ "$status" -eq 2 ]
}

# `show` reads only what is already rendered, so it has to keep working on the
# host whose configuration is the thing being diagnosed.
@test "show still works when the configuration is unusable" {
    mkdir -p "$STUB_DIR/owner"; echo example.com > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]
    rm -f "$T/token"
    run_tool show
    [ "$status" -eq 0 ]
    [[ "$output" == *"server=/example.com/"* ]]
}

# "no config at ..." was what a non-root user saw for a file sitting right
# there at a root-owned path - sending them to create something that already
# existed. The two cases need different messages because they need different
# actions.
@test "a config behind an unsearchable directory is not reported as missing" {
    # /etc/dejima-ci is 0750 root-owned, so every unprivileged run cannot even
    # stat the file inside it. Reporting that as "no config - run install.sh"
    # sends someone to redo an install that already succeeded, when the only
    # thing missing is sudo.
    [ "$(id -u)" -ne 0 ] || skip "root searches any directory, so this cannot arise"
    mkdir -p "$T/locked"
    cp "$T/config" "$T/locked/config"
    chmod 000 "$T/locked"
    run "$BIN" check --config "$T/locked/config"
    chmod 755 "$T/locked"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not searchable"* ]]
    [[ "$output" == *"sudo"* ]]
    [[ "$output" != *"run install.sh to create it"* ]]
}

@test "a missing config says so, and says what creates one" {
    # Not run_tool: it appends its own --config, which would win over this one.
    run "$BIN" check --config "$T/does-not-exist"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no config at"* ]]
    [[ "$output" == *"install.sh"* ]]
}

@test "an unreadable config is a different message from a missing one" {
    # Only a caller who cannot read the file ever sees this branch, which makes
    # the assertion depend on who is running it. `[ -r ]` is access(2) with
    # R_OK, and that always succeeds for a process holding CAP_DAC_OVERRIDE -
    # so as root the file is readable at mode 000, the branch is unreachable,
    # and this fails on the privilege of the caller rather than on anything the
    # program does.
    #
    # Skipped rather than asserted-around, because there is nothing here to
    # check when the caller can bypass the permission being tested. CI runs the
    # suite as an ordinary user precisely so that this runs there.
    [ "$(id -u)" -ne 0 ] || skip "root reads a mode-000 file, so this branch is unreachable"

    chmod 000 "$T/config"
    run_tool render
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not readable by"* ]]
    [[ "$output" == *"sudo"* ]]
    [[ "$output" != *"no config at"* ]]
    chmod 644 "$T/config"
}

# --- the base list is a config file, not a domain list -----------------------

@test "a comment in base-domains is a comment, not a malformed domain" {
    # It was cat'd raw while the repos file one line below was comment-stripped,
    # and install.sh strips comments when it reads this same file back. So a
    # `#` line here reached valid_domain and killed the run with "refusing a
    # malformed entry: #namesallowedregardless...", which names no file and
    # sends an operator to /etc/dejima-ci/config - a file that legitimately has
    # a comment at the top, put there by install.sh, and was never the problem.
    mkdir -p "$STUB_DIR/owner"; echo example.com > "$STUB_DIR/owner/repo.body"
    printf '# names allowed regardless of any declaration\nbase.example.com\n' > "$T/base"
    run_tool render
    [ "$status" -eq 0 ]
    grep -q '^server=/base.example.com/' "$T/out/ci-allow.conf"
    ! grep -q '#names' "$T/out/ci-allow.conf"
}

@test "a malformed entry says which file it might have come from" {
    # Two files can produce one, and they are edited by different people at
    # different times. Naming neither leaves the operator grepping for a `#`.
    mkdir -p "$STUB_DIR/owner"; printf 'not a domain!\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 2 ]
    [[ "$output" == *"$T/base"* ]]
    [[ "$output" == *"$T/repos"* ]]
}

@test "collection says what each repository contributed" {
    # "My project declared domains and got none of them" had no diagnostic
    # anywhere: a repository absent from repos_file is never fetched, so it
    # produced no line, no error and no trace.
    mkdir -p "$STUB_DIR/owner"; printf 'a.example.com\nb.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [[ "$output" == *"owner/repo: 2 name(s) declared"* ]]
}

@test "a repository with no declaration says so rather than staying silent" {
    mkdir -p "$STUB_DIR/owner"
    echo 404 > "$STUB_DIR/owner/repo.status"
    echo base.example.com > "$T/base"
    run_tool render
    [[ "$output" == *"owner/repo: no .dejima/allowed-domains"* ]]
}

# --- trusting a repository without re-running the installer ------------------

@test "repos list prints the trusted repositories" {
    printf 'acme/one\nacme/two\n' > "$T/repos"
    run_tool repos list
    [ "$status" -eq 0 ]
    [[ "$output" == *"acme/one"* ]]
    [[ "$output" == *"acme/two"* ]]
}

@test "repos add trusts one without touching the others" {
    # The whole point. Adding one used to mean re-running install.sh and
    # retyping every entry already there, from memory.
    printf 'acme/one\nacme/two\n' > "$T/repos"
    run_tool repos add acme/three
    [ "$status" -eq 0 ]
    for r in acme/one acme/two acme/three; do
        grep -qx "$r" "$T/repos" || { echo "lost $r"; false; }
    done
}

@test "repos add is idempotent" {
    printf 'acme/one\n' > "$T/repos"
    run_tool repos add acme/one
    [ "$(grep -c . "$T/repos")" -eq 1 ]
    [[ "$output" == *"already trusted"* ]]
}

@test "repos remove takes one out and leaves the rest" {
    printf 'acme/one\nacme/two\n' > "$T/repos"
    run_tool repos remove acme/one
    ! grep -qx acme/one "$T/repos"
    grep -qx acme/two "$T/repos"
}

@test "repos add refuses something that is not owner/repo" {
    printf 'acme/one\n' > "$T/repos"
    run_tool repos add "https://example.com/acme/two"
    [ "$status" -eq 2 ]
    [ "$(grep -c . "$T/repos")" -eq 1 ]
}

@test "repos says the list is not live until the allowlist is rebuilt" {
    # Editing the file changes nothing on its own. An operator who adds a repo
    # and walks away has done half a job.
    printf 'acme/one\n' > "$T/repos"
    run_tool repos add acme/two
    [[ "$output" == *"render"* ]]
}

@test "repos works without a usable forge configuration" {
    # It edits a list of names. Requiring a working token and resolver to do
    # that would make it useless on the host whose configuration is the thing
    # being diagnosed.
    rm -f "$T/token"
    printf 'acme/one\n' > "$T/repos"
    run_tool repos list
    [ "$status" -eq 0 ]
}

@test "repos honours --config placed after the operands" {
    # `repos` used to consume the rest of the line where it was seen, so a
    # following --config was swallowed and the edit landed in whatever the
    # default config pointed at. Silently, on the file that decides whose
    # branch may widen an allowlist.
    printf 'acme/one\n' > "$T/repos"
    run "$BIN" repos add acme/two --config "$T/config"
    [ "$status" -eq 0 ]
    grep -qx acme/two "$T/repos"
}

@test "a comment in a repository's declaration is a comment too" {
    # The first fix stripped base-domains and nothing else, and the very next
    # run on a real host died on a bare `#` from a repository's own
    # declaration. A fetched body was cat'd raw, so the bug was the same one a
    # layer over. Both arrive at one place now, and that is where stripping
    # happens.
    mkdir -p "$STUB_DIR/owner"
    printf '# what this project needs\n#\n# and why\nreal.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]
    grep -q '^server=/real.example.com/' "$T/out/ci-allow.conf"
    [ "$(grep -c '^server=' "$T/out/ci-allow.conf")" -eq 1 ]
}

@test "a bare hash line does not become an entry" {
    # Exactly what a real host produced: `refusing a malformed entry: #`. A
    # separator line in a comment block, which is how this organisation's own
    # generated files are written.
    mkdir -p "$STUB_DIR/owner"
    printf '#\nreal.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]
}

@test "the declared count is names, not lines" {
    # A comment block counted as declared names, so a repository reporting
    # "15 name(s) declared" might be declaring rather fewer.
    mkdir -p "$STUB_DIR/owner"
    printf '# three comment lines\n#\n# here\none.example.com\ntwo.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [[ "$output" == *"owner/repo: 2 name(s) declared"* ]]
}
# --- revoking a name --------------------------------------------------------
#
# dnsmasq puts the addresses it answers with into the firewall's set, and
# nothing took them out again. After a re-render the name stopped resolving and
# every address it had ever resolved to stayed reachable until the host
# rebooted, so removing a domain from a declaration revoked nothing.

stub_ipset() {
    cat > "$T/stub/ipset" <<'IPSETEOF'
#!/usr/bin/env bash
case "$1" in
    list) printf '%s\n' "${STUB_IPSET_NAMES:-ci-allow}" ;;
    create) ;;
    flush) printf '%s\n' "$2" >> "$STUB_DIR/flushed" ;;
esac
exit 0
IPSETEOF
    chmod +x "$T/stub/ipset"
}

@test "a revocation flushes the project sets, not just the bare name" {
    # The config key is a prefix now: names live in a set per project plus a
    # base set, and the bare name holds nothing. Flushing it alone would empty
    # an unused set and report a revocation that had not happened.
    stub_ipset
    STUB_IPSET_NAMES=$'ci-allow\nci-allow-base\nci-allow-1'
    export STUB_IPSET_NAMES
    mkdir -p "$STUB_DIR/owner"
    printf 'keep.example.com\ndrop.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    printf 'keep.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]
    grep -qx ci-allow-1 "$STUB_DIR/flushed"
    grep -qx ci-allow-base "$STUB_DIR/flushed"
}

@test "a set belonging to something else is not flushed" {
    # The prefix is the boundary. Another tool's set on the same host is not
    # this program's to empty.
    stub_ipset
    STUB_IPSET_NAMES=$'ci-allow-1\nsomeone-elses-set'
    export STUB_IPSET_NAMES
    mkdir -p "$STUB_DIR/owner"
    printf 'keep.example.com\ndrop.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    printf 'keep.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    ! grep -qx someone-elses-set "$STUB_DIR/flushed"
}

@test "removing a name flushes the set, or it stays reachable by address" {
    stub_ipset
    mkdir -p "$STUB_DIR/owner"
    printf 'keep.example.com\ndrop.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]

    printf 'keep.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]
    grep -qx ci-allow "$STUB_DIR/flushed"
    [[ "$output" == *"1 name(s) revoked"* ]]
}

@test "adding a name does not flush, since nothing was revoked" {
    # A flush on every change would empty the set whenever a name was added,
    # and a job mid-run would find a destination it had already resolved
    # refused until it looked it up again.
    stub_ipset
    mkdir -p "$STUB_DIR/owner"
    printf 'one.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    printf 'one.example.com\ntwo.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_DIR/flushed" ]
}

@test "an unchanged render flushes nothing and reloads nothing" {
    stub_ipset
    mkdir -p "$STUB_DIR/owner"
    printf 'one.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    run_tool render
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_DIR/flushed" ]
}

@test "a missing set is reported rather than passed over" {
    # The names go out of the resolver either way, so this half-succeeds. An
    # operator who is not told will believe a revocation took effect.
    stub_ipset
    mkdir -p "$STUB_DIR/owner"
    printf 'keep.example.com\ndrop.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    printf 'keep.example.com\n' > "$STUB_DIR/owner/repo.body"
    STUB_IPSET_NAMES="something-else" run_tool render
    [[ "$output" == *"stays reachable"* ]]
}

@test "the flush happens before the reload, not after" {
    # The reload is a SIGHUP, which clears dnsmasq's cache. Flushing after it
    # would leave cached answers that repopulate nothing, so names still on the
    # list would be unreachable until their TTL ran out.
    stub_ipset
    cat > "$T/stub/reloader" <<'RELEOF'
#!/usr/bin/env bash
printf 'reload\n' >> "$STUB_DIR/order"
RELEOF
    chmod +x "$T/stub/reloader"
    cat > "$T/stub/ipset" <<'IPSETEOF'
#!/usr/bin/env bash
case "$1" in
    list) printf 'ci-allow\n' ;;
    flush) printf 'flush\n' >> "$STUB_DIR/order" ;;
esac
exit 0
IPSETEOF
    chmod +x "$T/stub/ipset"
    sed -i "s|^reload = .*|reload = $T/stub/reloader|" "$T/config"

    mkdir -p "$STUB_DIR/owner"
    printf 'keep.example.com\ndrop.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    : > "$STUB_DIR/order"          # the first render installs and reloads too
    printf 'keep.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$(head -1 "$STUB_DIR/order")" = flush ]
    [ "$(tail -1 "$STUB_DIR/order")" = reload ]
}

# --- scoping a project to its own set ----------------------------------------
#
# One list and one set meant every project's declaration was reachable from
# every project's jobs. The set is the part that matters: it holds addresses
# with no memory of which name put them there, so scoping the resolver alone
# would leave a project able to connect by address to anything another project
# resolved.

@test "a declaration with no set of its own refuses the render" {
    # There is no shared fallback. A set every project can reach is the thing
    # this exists to end, and falling back to one would be arriving there by
    # doing nothing rather than by choosing it.
    : > "$T/pools"
    mkdir -p "$STUB_DIR/owner"; echo one.example.com > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 2 ]
    [[ "$output" == *"owner/repo"* ]]
    [[ "$output" == *"pools add"* ]]
}

@test "a refused render leaves the allowlist that was already there" {
    # The cost of an unfinished migration is a loud error on the timer, not a
    # host that has lost its allowlist.
    mkdir -p "$STUB_DIR/owner"; echo one.example.com > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]
    before=$(cat "$T/out/ci-allow.conf")
    : > "$T/pools"
    run_tool render
    [ "$status" -eq 2 ]
    [ "$(cat "$T/out/ci-allow.conf")" = "$before" ]
}

@test "a repository that declares nothing needs no set" {
    # It has no names to scope. Requiring an assignment would be friction with
    # nothing behind it.
    : > "$T/pools"
    mkdir -p "$STUB_DIR/owner"; echo 404 > "$STUB_DIR/owner/repo.status"
    echo base.example.com > "$T/base"
    run_tool render
    [ "$status" -eq 0 ]
}

@test "base names go in a set of their own, not the shared one" {
    # Otherwise an assigned project matching base would be matching every
    # unassigned project too, and the scoping would be for nothing.
    mkdir -p "$STUB_DIR/owner"; echo one.example.com > "$STUB_DIR/owner/repo.body"
    echo base.example.com > "$T/base"
    run_tool render
    grep -qx 'ipset=/base.example.com/ci-allow-base' "$T/out/ci-allow.conf"
}

@test "an assigned project's names go in its own set" {
    printf 'owner/repo 1\n' > "$T/pools"
    mkdir -p "$STUB_DIR/owner"; echo one.example.com > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 0 ]
    grep -qx 'ipset=/one.example.com/ci-allow-1' "$T/out/ci-allow.conf"
    ! grep -qx 'ipset=/one.example.com/ci-allow' "$T/out/ci-allow.conf"
}

@test "a name two projects declare lands in both their sets" {
    # dnsmasq takes several sets per name, which is what lets one resolver
    # serve every project without the answer widening anyone else's reach.
    printf 'owner/repo 1\nother/repo 2\n' > "$T/pools"
    printf 'owner/repo\nother/repo\n' > "$T/repos"
    mkdir -p "$STUB_DIR/owner" "$STUB_DIR/other"
    echo shared.example.com > "$STUB_DIR/owner/repo.body"
    echo shared.example.com > "$STUB_DIR/other/repo.body"
    run_tool render
    grep -qx 'ipset=/shared.example.com/ci-allow-1,ci-allow-2' "$T/out/ci-allow.conf"
}

@test "a name one project declares does not reach the other's set" {
    # The whole point.
    printf 'owner/repo 1\nother/repo 2\n' > "$T/pools"
    printf 'owner/repo\nother/repo\n' > "$T/repos"
    mkdir -p "$STUB_DIR/owner" "$STUB_DIR/other"
    echo mine.example.com > "$STUB_DIR/owner/repo.body"
    echo theirs.example.com > "$STUB_DIR/other/repo.body"
    run_tool render
    grep -qx 'ipset=/mine.example.com/ci-allow-1' "$T/out/ci-allow.conf"
    grep -qx 'ipset=/theirs.example.com/ci-allow-2' "$T/out/ci-allow.conf"
}

@test "every name still resolves, since the scoping is the set and not the view" {
    # One dnsmasq has one view. The leak is names, which are public in the
    # repositories they come from; what a job can reach is the set.
    printf 'owner/repo 1\n' > "$T/pools"
    mkdir -p "$STUB_DIR/owner"; echo one.example.com > "$STUB_DIR/owner/repo.body"
    run_tool render
    grep -q '^server=/one.example.com/' "$T/out/ci-allow.conf"
}

@test "the name count is names, not lines" {
    # Each name emits a server= and an ipset= line now. Counting lines and
    # subtracting the header reported double.
    mkdir -p "$STUB_DIR/owner"; printf 'a.example.com\nb.example.com\n' > "$STUB_DIR/owner/repo.body"
    run_tool render
    [[ "$output" == *"2 names"* ]]
}

@test "pools add gives out an id and never reuses one" {
    # An id names a set and a bridge that may still hold addresses and still
    # carry rules. Handing a freed one to a different pool would give it
    # whatever the last occupant left behind.
    : > "$T/pools"
    run_tool pools add acme/one
    run_tool pools add acme/two
    run_tool pools remove acme/one
    run_tool pools add acme/three
    [ "$(awk '$1 == "acme/three" { print $2 }' "$T/pools")" = 3 ]
}

@test "pools add is idempotent" {
    : > "$T/pools"
    run_tool pools add acme/one
    run_tool pools add acme/one
    [ "$(grep -c 'acme/one' "$T/pools")" -eq 1 ]
    [[ "$output" == *"already has id"* ]]
}

@test "pools add says what has to happen before it means anything" {
    # Writing the file scopes nothing on its own: the allowlist has to be
    # re-rendered, the firewall has to point the bridge at the set, and the
    # pool's runners have to be on that network.
    : > "$T/pools"
    run_tool pools add acme/one
    [[ "$output" == *"render"* ]]
    [[ "$output" == *"dejima-ci-firewall"* ]]
    [[ "$output" == *"--pool"* ]]
}

@test "pools add says the registration is what decides, not the label" {
    # A branch chooses its own runs-on, so a label is a request. What a runner
    # may take is decided by what it is registered to, which a branch cannot
    # change.
    : > "$T/pools"
    run_tool pools add acme/one
    [[ "$output" == *"REGISTERED"* ]]
    [[ "$output" == *"label"* ]]
}

@test "pools list explains what a scope is" {
    run_tool pools list
    [[ "$output" == *"REGISTERED"* ]]
    [[ "$output" == *"bare owner"* ]]
}

# --- an owner-scoped pool holds the union it can actually run ----------------

@test "an owner-scoped pool gets every repository of that owner" {
    # Safe, because a pool takes jobs from the repositories it is registered
    # for: a hostile branch in one of them can already put a job on it, so its
    # names being in that pool's set gives away nothing new.
    printf 'acme 1
' > "$T/pools"
    printf 'acme/one
acme/two
' > "$T/repos"
    mkdir -p "$STUB_DIR/acme"
    echo one.example.com > "$STUB_DIR/acme/one.body"
    echo two.example.com > "$STUB_DIR/acme/two.body"
    run_tool render
    [ "$status" -eq 0 ]
    grep -qx 'ipset=/one.example.com/ci-allow-1' "$T/out/ci-allow.conf"
    grep -qx 'ipset=/two.example.com/ci-allow-1' "$T/out/ci-allow.conf"
}

@test "a repository-scoped pool does not get the owner's other repositories" {
    # The reason repository scoping is the recommendation: it is how a pool
    # gets a small set.
    printf 'acme/one 1
acme 2
' > "$T/pools"
    printf 'acme/one
acme/two
' > "$T/repos"
    mkdir -p "$STUB_DIR/acme"
    echo one.example.com > "$STUB_DIR/acme/one.body"
    echo two.example.com > "$STUB_DIR/acme/two.body"
    run_tool render
    # acme/one runs on both pools, so both may reach its name.
    grep -qx 'ipset=/one.example.com/ci-allow-1,ci-allow-2' "$T/out/ci-allow.conf"
    # acme/two runs only on the owner pool, and the repository pool never sees it.
    grep -qx 'ipset=/two.example.com/ci-allow-2' "$T/out/ci-allow.conf"
}

@test "a declaration no pool can run refuses the render" {
    # Almost always a repository trusted to widen the allowlist and never given
    # a runner, which is a job queueing rather than a security decision.
    # Rendering its names into nothing would hide that.
    printf 'other/repo 1
' > "$T/pools"
    mkdir -p "$STUB_DIR/owner"; echo one.example.com > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 2 ]
    [[ "$output" == *"owner/repo"* ]]
    [[ "$output" == *"pools add"* ]]
}

@test "an owner scope does not match a different owner" {
    printf 'other 1
' > "$T/pools"
    mkdir -p "$STUB_DIR/owner"; echo one.example.com > "$STUB_DIR/owner/repo.body"
    run_tool render
    [ "$status" -eq 2 ]
}

# --- the migration an operator actually performs -----------------------------

@test "pools add creates the network rather than printing it to paste" {
    # The bridge name has to match what the firewall writes rules for, and it is
    # the one value in the procedure that nothing else checks: a typo produces a
    # network that works, a set that fills, and a firewall rule for an interface
    # that does not exist.
    cat > "$T/stub/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/docker.log"
case "$1 $2" in
    "network inspect") exit 1 ;;   # not there yet
esac
exit 0
DOCKEREOF
    chmod +x "$T/stub/docker"
    : > "$T/pools"
    run_tool pools add acme/one
    [ "$status" -eq 0 ]
    grep -q 'network create' "$STUB_DIR/docker.log"
    grep -q 'com.docker.network.bridge.name=dejima-ci1' "$STUB_DIR/docker.log"
    [[ "$output" == *"created network"* ]]
}

@test "pools add leaves a network that is already there" {
    cat > "$T/stub/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/docker.log"
exit 0
DOCKEREOF
    chmod +x "$T/stub/docker"
    : > "$T/pools"
    run_tool pools add acme/one
    ! grep -q 'network create' "$STUB_DIR/docker.log"
    [[ "$output" == *"already exists"* ]]
}

@test "pools add on a host without docker says what to run where" {
    # The allowlist can be edited from somewhere that is not the runner host.
    : > "$T/pools"
    PATH="/usr/bin:/bin" run "$BIN" pools add acme/one --config "$T/config"
    [[ "$output" == *"docker is not on this host"* ]]
    [[ "$output" == *"network create"* ]]
}

@test "pools add points at the pool by name, not at a network and a path" {
    # Two values that have to agree, in a command run once per pool. The second
    # time, the path is the part that obviously differs, so the network stays as
    # it was and both pools end up on the first one's.
    : > "$T/pools"
    run_tool pools add acme/one
    [[ "$output" == *"--pool acme/one"* ]]
    [[ "$output" != *"--network dejima-ci-1 --dir"* ]]
}

@test "pools add records the runner project when given one" {
    : > "$T/pools"
    run_tool pools add acme/one /srv/runners/one
    [ "$(awk '$1 == "acme/one" { print $3 }' "$T/pools")" = /srv/runners/one ]
}

@test "pools add on an existing scope records the project rather than refusing" {
    : > "$T/pools"
    run_tool pools add acme/one
    run_tool pools add acme/one /srv/runners/one
    [ "$(awk '$1 == "acme/one" { print $3 }' "$T/pools")" = /srv/runners/one ]
    [[ "$output" == *"--pool acme/one"* ]]
}

@test "a pool with no project recorded says it cannot be moved by name" {
    : > "$T/pools"
    run_tool pools add acme/one
    run_tool pools add acme/one
    [[ "$output" == *"not recorded"* ]]
}

@test "pools list shows the network and the project for each pool" {
    printf 'acme/one 1 /srv/runners/one\nacme 2\n' > "$T/pools"
    run_tool pools list
    [[ "$output" == *"dejima-ci-1"* ]]
    [[ "$output" == *"/srv/runners/one"* ]]
    [[ "$output" == *"not recorded"* ]]
}

# --- does the host agree with the file ---------------------------------------
#
# Four things have to line up, each written by a different command at a
# different time: the pools file, docker's network, iptables' rules, and the
# runner project. Three of them agreeing is not scoping, and every way of
# getting it wrong looks like it worked.

verify_stubs() {  # verify_stubs [rules-file]
    # The resolver's address, on the shared bridge. Losing it takes DNS from
    # every pool at once, so verify checks for it and the fixture has to have
    # one for anything else to be exercised.
    cat > "$T/stub/ip" <<'EOF2'
#!/usr/bin/env bash
case "$*" in
  *"addr show dev dejima-ci0"*) [ -n "${STUB_NO_GW:-}" ] || echo "1: dejima-ci0    inet 192.0.2.1/24 scope global" ;;
  *"addr show dev"*) ;;
  *"addr show"*) [ -n "${STUB_NO_GW:-}" ] || echo "1: dejima-ci0    inet 192.0.2.1/24 scope global" ;;
esac
exit 0
EOF2
    chmod +x "$T/stub/ip"
    grep -q '^gateway' "$T/config" || echo "gateway = 192.0.2.1" >> "$T/config"
    cat > "$T/stub/docker" <<'EOF2'
#!/usr/bin/env bash
case "$*" in *"network inspect dejima-ci-1"*) echo "dejima-ci1"; exit 0 ;; esac
exit 1
EOF2
    cat > "$T/stub/ipset" <<'EOF2'
#!/usr/bin/env bash
[ "$1" = list ] && printf '%s\n' "${STUB_SETS:-ci-allow-base ci-allow-1}" | tr ' ' '\n'
exit 0
EOF2
    cat > "$T/stub/iptables" <<EOF2
#!/usr/bin/env bash
cat "${1:-$T/rules}" 2>/dev/null
exit 0
EOF2
    chmod +x "$T/stub/docker" "$T/stub/ipset" "$T/stub/iptables"
    mkdir -p "$T/proj"; printf '  network: "dejima-ci-1"\n' > "$T/proj/config.yaml"
    printf 'acme/one 1 %s/proj\n' "$T" > "$T/pools"
    cat > "$T/rules" <<'EOF2'
-A DEJIMA-CI-FWD -i dejima-ci1 -p tcp -m set --match-set ci-allow-1 dst -j ACCEPT
-A DEJIMA-CI-FWD -i dejima-ci1 -p tcp -m set --match-set ci-allow-base dst -j ACCEPT
EOF2
}

@test "verify passes a host that agrees with its pools file" {
    verify_stubs
    run_tool verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"Everything agrees"* ]]
}

@test "verify catches a bridge matching another pool's set" {
    # The failure this whole design exists to prevent, and the one that is
    # invisible from every other angle: the runners register and the jobs pass.
    verify_stubs
    printf -- '-A DEJIMA-CI-FWD -i dejima-ci1 -p tcp -m set --match-set ci-allow-2 dst -j ACCEPT\n' >> "$T/rules"
    run_tool verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"which is another pool's"* ]]
}

@test "verify catches runners on the wrong network" {
    verify_stubs
    printf '  network: "dejima-ci-9"\n' > "$T/proj/config.yaml"
    run_tool verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"carry another pool's allowlist"* ]]
}

@test "verify catches a bridge with no rule at all" {
    verify_stubs
    : > "$T/rules"
    run_tool verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"no allowlist rule"* ]]
}

@test "a bridge with no rules does not stop the checks after it" {
    # grep answers "nothing matched" with a non-zero status, and under pipefail
    # that aborted the run. The one pool that needed reporting took every check
    # after it down too, leaving a report that looked merely short.
    verify_stubs
    printf 'acme/one 1 %s/proj\nacme 2 %s/proj\n' "$T" "$T" > "$T/pools"
    run_tool verify
    [[ "$output" == *"acme"* ]]
    [[ "$output" == *"problem(s)"* ]]
}

@test "a bridge with jobs on it and no pool is a failure" {
    # Containers on a bridge no pool describes are jobs running under an
    # allowlist nothing here decided.
    verify_stubs
    cat > "$T/stub/docker" <<'EOF2'
#!/usr/bin/env bash
case "$*" in
  *"network ls"*) printf 'dejima-ci-9
' ;;
  *"network inspect dejima-ci-1"*) echo "dejima-ci1" ;;
  *'{{index .Options "com.docker.network.bridge.name"}}'*) echo "dejima-ci9" ;;
  *"{{len .Containers}}"*) echo 3 ;;
  *) exit 1 ;;
esac
exit 0
EOF2
    chmod +x "$T/stub/docker"
    printf -- '-A DEJIMA-CI-FWD -i dejima-ci9 -p tcp -m set --match-set ci-allow-9 dst -j ACCEPT\n' >> "$T/rules"
    run_tool verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"3 container(s) and no pool claims it"* ]]
    [[ "$output" == *"--pool"* ]]
}

@test "a bridge with nothing on it is a note, not a failure" {
    # Rules for a bridge nothing is on are untidy rather than unsafe. A verifier
    # that cries about leftovers is one whose real findings get skimmed past.
    verify_stubs
    printf -- '-A DEJIMA-CI-FWD -i dejima-ci9 -p tcp -m set --match-set ci-allow-9 dst -j ACCEPT\n' >> "$T/rules"
    run_tool verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing is on it"* ]]
    [[ "$output" == *"dejima-ci-firewall"* ]]
}

@test "the shared bridge with rules is expected, not something to tidy" {
    # It holds the address every pool resolves against, and its rules contain
    # anything that lands on it. Suggesting either half be removed was wrong
    # twice over: once for DNS, once for egress.
    verify_stubs
    echo "bridge = dejima-ci0" >> "$T/config"
    printf -- '-A DEJIMA-CI-FWD -i dejima-ci0 -p tcp -m set --match-set ci-allow-base dst -j ACCEPT\n' >> "$T/rules"
    run_tool verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"is the shared network"* ]]
    [[ "$output" != *"docker network rm"* ]]
    [[ "$output" != *"set 'bridge ='"* ]]
}

@test "a resolver address on no interface is a failure, not a note" {
    # Losing it takes DNS from every pool at once, and the symptom is jobs
    # failing in apt rather than anything naming a resolver.
    verify_stubs
    STUB_NO_GW=1 run_tool verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot answer"* ]]
    [[ "$output" == *"docker network create"* ]]
}

@test "verify refuses to pass what it could not check" {
    # A verifier that reports success when it did not look is worse than no
    # verifier, because it is the one that gets believed.
    verify_stubs
    # No gateway either, or the check for it runs with the real `ip` and reports
    # a genuine failure, which is a different answer from "could not look".
    sed -i '/^gateway /d' "$T/config"
    # A PATH without /usr/sbin, rather than deleting the stubs: this container
    # has a real iptables and a real ipset, so removing the stubs finds those
    # instead of finding nothing.
    PATH="/usr/bin:/bin" run "$BIN" verify --config "$T/config"
    [ "$status" -eq 2 ]
    [[ "$output" == *"could not be checked"* ]]
    [[ "$output" != *"Everything agrees"* ]]
}

@test "verify with no pools declared says so rather than passing" {
    verify_stubs
    : > "$T/pools"
    run_tool verify
    [ "$status" -eq 2 ]
    [[ "$output" == *"no pools declared"* ]]
}

@test "install.sh --tools deploys programs without the setup flow" {
    # Most upgrades change only what is in bin/, and running the whole installer
    # to put them there means answering prompts about a network, a resolver and
    # a token that are already correct.
    inst="${BATS_TEST_DIRNAME}/../install.sh"
    grep -q '\-\-tools) TOOLS_ONLY=1' "$inst"
    grep -q '^deploy_files() {' "$inst"
}

@test "--tools on a host with no config refuses rather than half-installing" {
    # The programs would have nothing to read, and an installer that looks like
    # it worked is worse than one that says what it did not do.
    grep -q 'no \$CONF_DIR/config on this host' "${BATS_TEST_DIRNAME}/../install.sh"
}

@test "a network whose bridge has no rules is a failure" {
    # The direction that fails open. Every rule names an interface, so a bridge
    # with none matches nothing, falls off the end of the chain and returns to
    # Docker's default, which accepts. The network works and the jobs pass, and
    # nothing is filtering them.
    verify_stubs
    cat > "$T/stub/docker" <<'EOF2'
#!/usr/bin/env bash
case "$*" in
  *"network ls"*) printf 'dejima-ci
dejima-ci-1
' ;;
  *"inspect dejima-ci-1 --format"*) echo dejima-ci1 ;;
  *"inspect dejima-ci --format"*) echo dejima-ci0 ;;
  *"len .Containers"*) echo 0 ;;
  *) exit 1 ;;
esac
exit 0
EOF2
    chmod +x "$T/stub/docker"
    run_tool verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"which has no rules"* ]]
    [[ "$output" == *"reaches anything"* ]]
    [[ "$output" == *"bridge = dejima-ci0"* ]]
}

@test "the heading does not call the shared bridge a leftover" {
    # It is reported ok and described as expected, and sat under a heading
    # saying "unclaimed". A heading that disagrees with the line under it is
    # read before the line is.
    verify_stubs
    echo "bridge = dejima-ci0" >> "$T/config"
    printf -- '-A DEJIMA-CI-FWD -i dejima-ci0 -p tcp -m set --match-set ci-allow-base dst -j ACCEPT\n' >> "$T/rules"
    run_tool verify
    [[ "$output" != *"unclaimed"* ]]
}
