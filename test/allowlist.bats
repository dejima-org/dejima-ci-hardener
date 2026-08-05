#!/usr/bin/env bats
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

    cat > "$T/config" <<EOF
forge_api = https://gitea.example.com/api/v1
token_file = $T/token
repos_file = $T/repos
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

@test "check reports a pending change without installing it" {
    mkdir -p "$STUB_DIR/owner"; echo example.com > "$STUB_DIR/owner/repo.body"
    run_tool check
    [ "$status" -eq 1 ]
    [ ! -f "$T/out/ci-allow.conf" ]
}
