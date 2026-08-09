#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Drives bin/dejima-ci-runners against a stubbed docker, because the properties
# worth checking are all in what it renders rather than in what Docker does
# with it afterwards.
#
# The values under test are the ones whose halves disagreeing produces a runner
# that starts, accepts jobs, and enforces nothing - container.network against
# the network install.sh created, --dns against the resolver's address,
# docker_host against the tier. Every one of those failures is silent on the
# host and invisible in the forge, which is the whole reason they are generated
# rather than copied.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    RUNNERS="$REPO/bin/dejima-ci-runners"
    TMP="$BATS_TEST_TMPDIR"

    export TEMPLATE_DIR="$REPO/examples"
    export CONF_DIR="$TMP/conf"
    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/config" <<EOF
network = testnet
gateway = 10.99.0.1
forge_api = https://forge.example.com/api/v1
EOF
    printf 'acme/widget\n' > "$CONF_DIR/repos"

    # Enough docker for the generator to get past its preflight. It never
    # reaches `up` in these tests: --no-start stops before it.
    mkdir -p "$TMP/stub"
    cat > "$TMP/stub/docker" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "compose version" ] && { echo "Docker Compose version v2.29.0"; exit 0; }
exit 0
STUB
    # getent passwd, so the home the directory is derived from is this test's
    # rather than whoever is running it.
    cat > "$TMP/stub/getent" <<STUB
#!/bin/sh
[ "\$1" = passwd ] && { echo "tester:x:1000:1000::$TMP/home:/bin/bash"; exit 0; }
exec /usr/bin/getent "\$@"
STUB
    chmod +x "$TMP/stub/docker" "$TMP/stub/getent"
    export PATH="$TMP/stub:$PATH"

    OUT="$TMP/runners"
}

confined() {
    run bash "$RUNNERS" --role confined --dir "$OUT" --non-interactive --no-start "$@"
}
privileged() {
    run bash "$RUNNERS" --role privileged --dir "$OUT" --non-interactive --no-start \
        --forge https://forge.example.com "$@"
}

@test "the job network and resolver come from the config, not from a prompt" {
    confined
    [ "$status" -eq 0 ]
    grep -q '^  network: "testnet"$' "$OUT/config.yaml"
    grep -q -- '--dns=10.99.0.1 ' "$OUT/config.yaml"
}

@test "the confined tier denies job containers the Docker socket" {
    confined
    grep -q '^  docker_host: "-"$' "$OUT/config.yaml"
}

@test "the privileged tier grants it, and host networking with it" {
    privileged
    [ "$status" -eq 0 ]
    grep -q '^  docker_host: ""$' "$OUT/config.yaml"
    grep -q '^  network: host$' "$OUT/config.yaml"
}

@test "CONFIG_FILE is set, without which the config is never read at all" {
    confined
    grep -q 'CONFIG_FILE: /config.yaml' "$OUT/docker-compose.yml"
}

@test "the compose file mounts the config this run wrote, read-only" {
    confined
    grep -q './config.yaml:/config.yaml:ro' "$OUT/docker-compose.yml"
}

@test "one service and one data volume per runner asked for" {
    confined --count 4
    [ "$(grep -c 'container_name:' "$OUT/docker-compose.yml")" -eq 4 ]
    [ "$(grep -c -- '-data":$' "$OUT/docker-compose.yml")" -eq 4 ]
}

@test "the repeated block does not swallow the keys around it" {
    # The fence markers appear in the template's own explanatory header. A
    # substring match treated that sentence as the opening fence and consumed
    # the project name, the anchors and the services: key into the block.
    confined --count 2
    grep -q '^name: ' "$OUT/docker-compose.yml"
    grep -q '^services:$' "$OUT/docker-compose.yml"
    grep -q '^x-ci-runner: &ci-runner$' "$OUT/docker-compose.yml"
    grep -q '^volumes:$' "$OUT/docker-compose.yml"
}

@test "no template marker survives into either rendered file" {
    confined
    ! grep -q '@@' "$OUT/docker-compose.yml"
    ! grep -q '@@' "$OUT/config.yaml"
    privileged
    ! grep -q '@@' "$OUT/docker-compose.yml"
    ! grep -q '@@' "$OUT/config.yaml"
}

@test "the label reaches runs-on, the container name and the volume together" {
    confined --label pool-x --count 2
    grep -q '"pool-x:docker://' "$OUT/config.yaml"
    grep -q 'container_name: "pool-x-1"' "$OUT/docker-compose.yml"
    grep -q 'pool-x-2-data:/data' "$OUT/docker-compose.yml"
}

@test "the job image is what the label offers to run jobs in" {
    confined --job-image debian:bookworm
    grep -q 'docker://debian:bookworm"' "$OUT/config.yaml"
}

@test "the act_runner image is pinned to what was asked for" {
    confined --runner-image gitea/act_runner:0.7.0
    grep -q 'image: "gitea/act_runner:0.7.0"' "$OUT/docker-compose.yml"
}

@test "'none' means no host path may be bind-mounted, and is not the default" {
    privileged --volumes none
    grep -q '^  valid_volumes: \[\]$' "$OUT/config.yaml"
    privileged --volumes "/tmp/a /tmp/b"
    grep -q '^    - /tmp/a$' "$OUT/config.yaml"
    grep -q '^    - /tmp/b$' "$OUT/config.yaml"
}

@test "the token file is 0600, because it can register runners on your forge" {
    confined
    [ "$(stat -c %a "$OUT/.env")" = "600" ]
}

@test "a second run with the same answers changes nothing" {
    confined
    confined
    [ "$status" -eq 0 ]
    [[ "$output" == *"unchanged  $OUT/docker-compose.yml"* ]]
    [[ "$output" == *"unchanged  $OUT/config.yaml"* ]]
}

@test "a token already present is kept rather than blanked by a re-run" {
    confined
    printf 'GITEA_RUNNER_REGISTRATION_TOKEN=keepme\n' > "$OUT/.env"
    confined
    grep -q 'GITEA_RUNNER_REGISTRATION_TOKEN=keepme' "$OUT/.env"
}

@test "nothing is started while the token is still missing" {
    run bash "$RUNNERS" --role confined --dir "$OUT" --non-interactive
    [ "$status" -eq 0 ]
    [[ "$output" == *"No token yet"* ]]
}

@test "the token page named is the forge's, and org scope comes from repos" {
    confined
    [[ "$output" == *"https://forge.example.com/org/acme/settings/actions/runners"* ]]
    [[ "$output" == *"Do NOT use the instance-level page"* ]]
}

@test "a confined host with no job network is refused, not guessed at" {
    rm -f "$CONF_DIR/config"
    confined
    [ "$status" -ne 0 ]
    [[ "$output" == *"run install.sh first"* ]]
}

@test "a privileged host needs no config, since install.sh never ran there" {
    rm -f "$CONF_DIR/config"
    privileged
    [ "$status" -eq 0 ]
    grep -q 'GITEA_INSTANCE_URL: "https://forge.example.com"' "$OUT/docker-compose.yml"
}

@test "a forge that cannot be determined is an error rather than an empty URL" {
    rm -f "$CONF_DIR/config"
    run bash "$RUNNERS" --role privileged --dir "$OUT" --non-interactive --no-start
    [ "$status" -ne 0 ]
    [[ "$output" == *"forge URL is required"* ]]
}

@test "an api root given as the forge URL is not doubled up" {
    privileged --forge https://forge.example.com/api/v1
    grep -q 'GITEA_INSTANCE_URL: "https://forge.example.com"$' "$OUT/docker-compose.yml"
}

@test "the privileged tier is one runner regardless of --count" {
    privileged --count 5
    [ "$(grep -c 'container_name:' "$OUT/docker-compose.yml")" -eq 1 ]
}

@test "a count that is not a usable number stops rather than being coerced" {
    confined --count abc
    [ "$status" -ne 0 ]
    confined --count 0
    [ "$status" -ne 0 ]
    confined --count 99
    [ "$status" -ne 0 ]
}

@test "the old role spellings still work and say what they are now" {
    run bash "$RUNNERS" --role ci --dir "$OUT" --non-interactive --no-start
    [ "$status" -eq 0 ]
    [[ "$output" == *"--role ci is now --role confined"* ]]
}

@test "the templates themselves are parseable YAML" {
    # Not incidental. The markers are read in an editor - that is what makes
    # examples/ worth keeping - and a bare @@MARKER@@ as a value is invalid
    # YAML, because `@` is a reserved indicator that a plain scalar may not
    # begin with. Every marker standing in for a scalar is quoted for that
    # reason, and anything standing in for a structure is a fenced block.
    if ! command -v js-yaml >/dev/null 2>&1 && ! python3 -c 'import yaml' 2>/dev/null; then
        skip "no YAML parser available"
    fi
    parse() {
        if command -v js-yaml >/dev/null 2>&1; then js-yaml "$1" >/dev/null
        else python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$1"; fi
    }
    for f in "$TEMPLATE_DIR"/*.yaml "$TEMPLATE_DIR"/*.yml; do
        parse "$f" || { echo "unparseable template: $f"; return 1; }
    done
}

@test "with no --dir, the project lands under the group's own directory" {
    # The default has to exist and has to carry the group name: a prompt with
    # nothing in its brackets asks the operator to invent a path, and inventing
    # one is how a second group ends up somewhere the first cannot sit beside.
    run bash "$RUNNERS" --role confined --non-interactive --no-start --name grp
    [ "$status" -eq 0 ]
    [ -f "$TMP/home/runners/grp/docker-compose.yml" ]
    [ -f "$TMP/home/runners/grp/config.yaml" ]
}

@test "the derived directory follows the group name, not the label" {
    run bash "$RUNNERS" --role confined --non-interactive --no-start \
        --name second --label shared
    [ "$status" -eq 0 ]
    [ -d "$TMP/home/runners/second" ]
    [ ! -d "$TMP/home/runners/shared" ]
}

@test "two groups on one host can share a label without colliding" {
    # The reason to register a second token at all: one group at organization
    # scope and another for a user account, both answering the same label so
    # either scope's workflows reach a runner. Sharing the label is the point;
    # sharing a compose project, container names or volumes would mean the
    # second group quietly replacing the first.
    confined --name org --label shared --count 2
    [ "$status" -eq 0 ]

    OUT="$TMP/second" confined --name user --label shared --count 2
    [ "$status" -eq 0 ]

    grep -q '^name: "org-runners"$'  "$TMP/runners/docker-compose.yml"
    grep -q '^name: "user-runners"$' "$TMP/second/docker-compose.yml"
    grep -q 'container_name: "org-1"'  "$TMP/runners/docker-compose.yml"
    grep -q 'container_name: "user-1"' "$TMP/second/docker-compose.yml"
    grep -q '"org-1-data":'  "$TMP/runners/docker-compose.yml"
    grep -q '"user-1-data":' "$TMP/second/docker-compose.yml"

    # Nothing identifying one group appears in the other.
    ! grep -q 'user-' "$TMP/runners/docker-compose.yml"
    ! grep -q '\borg-' "$TMP/second/docker-compose.yml"

    # ...while both answer the same label, which is what a workflow names.
    grep -q '"shared:docker://' "$TMP/runners/config.yaml"
    grep -q '"shared:docker://' "$TMP/second/config.yaml"
}

@test "the group name defaults to the label, so one group needs no --name" {
    confined --label solo
    [ "$status" -eq 0 ]
    grep -q '^name: "solo-runners"$' "$OUT/docker-compose.yml"
    grep -q 'container_name: "solo-1"' "$OUT/docker-compose.yml"
}

@test "a group name that would break a path or a compose project is refused" {
    confined --name 'a/b'
    [ "$status" -ne 0 ]
    confined --name 'a b'
    [ "$status" -ne 0 ]
}

@test "both rendered files are parseable YAML" {
    if ! command -v js-yaml >/dev/null 2>&1 && ! python3 -c 'import yaml' 2>/dev/null; then
        skip "no YAML parser available"
    fi
    parse() {
        if command -v js-yaml >/dev/null 2>&1; then js-yaml "$1" >/dev/null
        else python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$1"; fi
    }
    confined --count 3
    parse "$OUT/docker-compose.yml"
    parse "$OUT/config.yaml"
    privileged
    parse "$OUT/docker-compose.yml"
    parse "$OUT/config.yaml"
}
