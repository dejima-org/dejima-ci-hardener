#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Asserts on the RUNNER, not on this repository. Every other suite here tests
# what this repository's programs decide, against stubs. This one tests the
# machine those programs configured, from inside a job on it - which is the
# only place the answer is knowable.
#
# It exists because both failures that matter look exactly like success from
# inside a job. Nothing in a job's log mentions whether the Docker socket was
# mounted into it, and a job that can reach an off-list resolver still passes
# every check that only inspects DOCKER-USER. Neither shows up as a red run;
# they show up as nothing at all.
#
# This is also the check the rest of the repository cannot make. install.sh
# reports what it wrote, dejima-ci-runners reports that a runner registered and
# is reading the config it generated - and a runner can do all of that while
# granting its jobs everything. The properties below are the ones the whole
# tool exists for, and they are only observable from in here.
#
# DEJIMA_CI_TIER says which runner this is supposed to be, set by the workflow
# rather than sniffed, so landing on the wrong runner is a failure rather than
# a different set of assertions quietly being chosen. Unset means this is not a
# CI runner and there is nothing here to assert - which is what makes the file
# safe to leave in `bats test/` on a laptop.
#
# Its values are the tier names this repository uses everywhere else, and the
# names of the jobs whose environment they verify. A reader looking at a red
# `runner-env (confined)` should not have to work out which job that is.

setup() {
    [ -n "${DEJIMA_CI_TIER:-}" ] || skip "not on a CI runner (DEJIMA_CI_TIER unset)"
    case "$DEJIMA_CI_TIER" in
        confined|privileged) ;;
        # The old spellings, so a workflow that has not caught up says so
        # rather than silently asserting nothing.
        ci|runtime|sandbox|host-docker)
            echo "DEJIMA_CI_TIER=$DEJIMA_CI_TIER is an old tier name." >&2
            echo "This repository's tiers are 'confined' and 'privileged'." >&2
            return 1 ;;
        *) echo "unknown DEJIMA_CI_TIER: $DEJIMA_CI_TIER" >&2; return 1 ;;
    esac
}

# An off-list destination that would answer if it were reachable. This matters
# more than it looks: pointing these at an address that never answers - a
# documentation range, say - would pass in an environment with no network at
# all, which is the exact failure this suite exists to detect.
OFF_LIST_IP=1.1.1.1

# The positive control's destination. Overridable because it has to be a name
# THIS runner allows, and an allowlist is per-operator - hardcoding one would
# fail on a runner correctly configured for a different set. The default is
# what install.sh offers in base-domains, and what .dejima/allowed-domains in
# this repository declares.
ALLOWED_HOST=${DEJIMA_CI_ALLOWED_HOST:-deb.debian.org}

connects() {  # connects HOST PORT -> 0 if a TCP connection completes
    python3 - "$1" "$2" <<'PY'
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=6).close()
except OSError:
    sys.exit(1)
PY
}

# --- the grant that decides everything --------------------------------------

@test "the confined tier does not hand jobs the Docker daemon" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "asserted for the confined runner"
    # act_runner mounts /var/run/docker.sock into every job container unless
    # container.docker_host is "-". An unset value is the default, and the
    # default mounts - so this is the assertion that a runner was actually
    # configured rather than merely intended.
    [ ! -e /var/run/docker.sock ] || {
        echo "this runner grants job containers the Docker socket, which is" >&2
        echo "root-equivalent on the runner host." >&2
        echo "" >&2
        echo "container.docker_host must be exactly \"-\" in its config.yaml." >&2
        echo "dejima-ci-runners --role confined writes that; if it is right in" >&2
        echo "the file and wrong here, check CONFIG_FILE=/config.yaml is in the" >&2
        echo "runner's environment - without it the file is not read at all." >&2
        false
    }
}

@test "the privileged tier does have the daemon it is scheduled for" {
    [ "$DEJIMA_CI_TIER" = privileged ] || skip "asserted for the privileged runner"
    # The positive control for the label routing. Without it, a privileged job
    # that landed on a confined runner would fail later and obscurely, and a
    # confined job that landed on this one would be caught only by the test
    # above - one direction of a two-direction problem.
    [ -e /var/run/docker.sock ]
}

@test "the privileged tier is in the host network namespace" {
    [ "$DEJIMA_CI_TIER" = privileged ] || skip "asserted for the privileged runner"
    # The tier's second grant, and the reason its jobs have no allowlist in
    # front of them. Read sysfs rather than shelling out to `ip`:
    # /sys/class/net is per-netns and always present, while iproute2 may not
    # be installed - which would turn "the tool is missing" into "the host
    # netns is missing".
    [ -e /sys/class/net/docker0 ] || {
        echo "this job is not in the host network namespace - docker0 is not" >&2
        echo "visible. Set container.network: host in the runner's config.yaml;" >&2
        echo "dejima-ci-runners --role privileged writes it." >&2
        false
    }
}

@test "the two tiers are not the same runner" {
    # Whatever else is true, exactly one of them gets the daemon. If both jobs
    # report the same answer here, the labels are not routing to two different
    # runners and the tiering exists only on paper.
    if [ "$DEJIMA_CI_TIER" = confined ]; then
        [ ! -e /var/run/docker.sock ]
    else
        [ -e /var/run/docker.sock ]
    fi
}

# --- egress, for the tier the rules actually apply to ------------------------
#
# Deliberately scoped to the confined runner. The privileged tier's jobs run in
# the HOST network namespace - that is the grant they exist for - so the bridge
# rules dejima-ci-firewall installs do not sit in front of them at all. Their
# egress is the host's own, bounded by the hypervisor rather than by anything
# this repository installs. Asserting an allowlist there would test nothing and
# pass anyway, which is the failure mode this whole suite is about.

@test "an allowlisted destination is reachable" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "bridge rules do not apply in the host netns"
    # The positive control for everything below. Without it, a runner with no
    # network at all passes every negative assertion in this file.
    run getent hosts "$ALLOWED_HOST"
    [ "$status" -eq 0 ] || {
        echo "$ALLOWED_HOST did not resolve, so the negative checks below" >&2
        echo "would pass for the wrong reason." >&2
        echo "" >&2
        echo "On the runner host: dejima-ci-allowlist show - is there a server=" >&2
        echo "line for this name? It comes from .dejima/allowed-domains on the" >&2
        echo "main branch of each served repository, plus base-domains. Or set" >&2
        echo "DEJIMA_CI_ALLOWED_HOST to a name this runner does allow." >&2
        false
    }
    run connects "$ALLOWED_HOST" 80
    [ "$status" -eq 0 ]
}

@test "a name that is on no allowlist does not resolve" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "bridge rules do not apply in the host netns"
    # .invalid is reserved by RFC 2606 precisely so that it never resolves
    # anywhere - but here it has to be REFUSED by a resolver that answers for
    # allowlisted names, which the positive control above establishes.
    run getent hosts example.invalid
    [ "$status" -ne 0 ]
}

@test "a job cannot reach a resolver of its own choosing" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "bridge rules do not apply in the host netns"
    # The check most easily left out, and the one that decides whether the DNS
    # allowlist means anything: a job that can query any resolver it likes can
    # resolve anything it likes, whatever dnsmasq is configured with. Traffic
    # to the resolver on the bridge gateway is addressed to the host, so it is
    # an INPUT packet and never passes through DOCKER-USER - filtering only
    # DOCKER-USER leaves this open.
    run connects "$OFF_LIST_IP" 53
    [ "$status" -ne 0 ] || {
        echo "reached $OFF_LIST_IP:53, so this job can use any resolver it likes" >&2
        echo "and the DNS allowlist is decorative. The INPUT rules are missing -" >&2
        echo "re-run dejima-ci-firewall on the runner host." >&2
        false
    }
}

@test "a destination that is on no allowlist is unreachable" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "bridge rules do not apply in the host netns"
    # An IP literal rather than a name, so this tests the firewall rather than
    # the resolver. Reaching it by name would fail at DNS first and prove
    # nothing about DOCKER-USER.
    run connects "$OFF_LIST_IP" 443
    [ "$status" -ne 0 ] || {
        echo "reached $OFF_LIST_IP:443, so this job has unrestricted egress." >&2
        echo "" >&2
        echo "If the DNS checks above passed, the resolver is fine and the packet" >&2
        echo "filter is not - which usually means DOCKER-USER is empty. Docker" >&2
        echo "recreates its own chains on every daemon start, so a 'systemctl" >&2
        echo "restart docker' drops these rules and nothing looks different" >&2
        echo "afterwards. Check with: iptables -S DOCKER-USER" >&2
        echo "" >&2
        echo "dejima-ci-firewall.service reapplies them on every Docker start," >&2
        echo "which is the fix rather than a one-off re-run." >&2
        false
    }
}

@test "IPv6 egress is not an unfiltered way around all of the above" {
    [ "$DEJIMA_CI_TIER" = confined ] || skip "bridge rules do not apply in the host netns"
    # An address family with no allowlist is not a smaller hole than the one
    # the rules above close; on a runner with IPv6 egress it is the same hole.
    #
    # Unlike the checks above, this one passes for two different reasons - v6
    # rejected, or v6 never configured - and both are acceptable outcomes, so
    # it is not given a positive control. What it rules out is the third case:
    # a runner with working IPv6 egress and rules written only for v4.
    run connects 2606:4700:4700::1111 443
    [ "$status" -ne 0 ]
}
