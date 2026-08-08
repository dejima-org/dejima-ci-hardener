#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Install dejima-ci-allowlist and walk through its configuration.
#
# Idempotent: re-running and pressing Enter at every prompt changes nothing.
# Existing values become the defaults, files are only rewritten when their
# content actually differs, and an existing token is kept unless you type a new
# one. So this is also the way to change one setting later.
#
# Runs on a CI host. Never on a host that runs dejima.

set -euo pipefail

PROG=${0##*/}
BIN_DIR=${BIN_DIR:-/usr/local/sbin}
CONF_DIR=${CONF_DIR:-/etc/dejima-ci}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
DNSMASQ_DIR=${DNSMASQ_DIR:-/etc/dnsmasq.d}
TEMPLATE_DIR=${TEMPLATE_DIR:-/usr/local/share/dejima-ci/templates}
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG="$CONF_DIR/config"
TOKEN_FILE="$CONF_DIR/forge-token"
REPOS_FILE="$CONF_DIR/repos"
BASE_FILE="$CONF_DIR/base-domains"

NONINTERACTIVE=0
[ -t 0 ] || NONINTERACTIVE=1
for a in "$@"; do
    case "$a" in
        -n|--non-interactive) NONINTERACTIVE=1 ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            echo
            echo "Usage: $PROG [--non-interactive]"
            exit 0 ;;
        *) echo "$PROG: unknown argument: $a" >&2; exit 2 ;;
    esac
done

die() { echo "$PROG: $*" >&2; exit 1; }
say() { printf '%s\n' "$*" >&2; }

# Writability rather than uid: root is only a proxy for being able to write
# these, and the proxy is wrong whenever the directories are overridden.
writable() { mkdir -p "$1" 2>/dev/null || true; [ -d "$1" ] && [ -w "$1" ]; }
for d in "$CONF_DIR" "$BIN_DIR"; do
    writable "$d" || die "cannot write $d - run as root, or set CONF_DIR/BIN_DIR/UNIT_DIR"
done
INSTALL_UNITS=1
writable "$UNIT_DIR" || INSTALL_UNITS=0

# --- prompting --------------------------------------------------------------
# Reads from the terminal rather than stdin, so this still works when the
# script itself arrived on a pipe.
ask() {
    local __var="$1" prompt="$2" def="${3:-}" reply=""
    if [ "$NONINTERACTIVE" -eq 0 ]; then
        if [ -n "$def" ]; then printf '%s [%s]: ' "$prompt" "$def" >&2
        else printf '%s: ' "$prompt" >&2; fi
        IFS= read -r reply </dev/tty || reply=""
    fi
    [ -n "$reply" ] || reply="$def"
    printf -v "$__var" '%s' "$reply"
}

# Only writes when the content differs, so a no-change run reports as such and
# leaves mtimes alone.
write_if_changed() {
    local path="$1" mode="$2" content="$3"
    if [ -f "$path" ] && [ "$content" = "$(cat "$path")" ]; then
        say "  unchanged  $path"
        chmod "$mode" "$path"
        return 0
    fi
    # Only create a missing parent, and never re-mode an existing one. This
    # writes into /etc/dnsmasq.d as well as its own directory, and tightening
    # a system directory that other tools read is not this installer's call to
    # make - as root it would have succeeded silently.
    [ -d "$(dirname "$path")" ] || install -d -m 0750 "$(dirname "$path")"
    printf '%s\n' "$content" > "$path.new"
    chmod "$mode" "$path.new"
    mv "$path.new" "$path"
    say "  written    $path"
}

# --- existing values become defaults ----------------------------------------
cfg_get() {
    local key="$1" line
    [ -r "$CONFIG" ] || return 0
    while IFS= read -r line; do
        line="${line%%#*}"
        [[ "$line" == *=* ]] || continue
        [ "$(echo "${line%%=*}" | tr -d '[:space:]')" = "$key" ] || continue
        echo "${line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
        return 0
    done < "$CONFIG"
}

# The upstream resolver is the setting people get wrong, so offer what this
# host already uses rather than making them go and find it.
detect_upstream() {
    local ip=""
    if command -v resolvectl >/dev/null 2>&1; then
        ip=$(resolvectl status 2>/dev/null \
            | awk '/DNS Servers:/ {print $3; exit}')
    fi
    [ -n "$ip" ] || ip=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
    printf '%s' "$ip"
}

# ipset in particular: the firewall's first command creates the set, so
# without it that script aborts at line one - and what it leaves behind
# resembles a working setup closely enough to pass a look. DNS still refuses
# unlisted names, because that is the resolver's doing rather than the
# firewall's, while every job has unrestricted egress.
missing=""
for tool in ipset iptables ip6tables dnsmasq docker; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
[ -z "$missing" ] || die "missing required commands:$missing
On Debian/Ubuntu: apt-get install ipset iptables dnsmasq docker.io

This installs nothing itself - it configures a machine you already have, and
adding a Docker daemon to one is not a thing to do on someone's behalf. On a
host built by dejima-ci-bootstrap these are already present; it installs them
before it gets here.

Without ipset the firewall cannot be applied, and a runner with no egress
policy looks exactly like one with. Without docker there is no job network to
create, which is the first thing this does."

say "dejima-ci-hardener installer"
say
say "This renders the CI job network's DNS allowlist from .dejima/allowed-domains"
say "on each served repository's main branch. Press Enter to keep a value shown"
say "in brackets."
say

# --- the job network --------------------------------------------------------
say "=============================================================="
say " The job network"
say "=============================================================="
say
say "A Docker network for job containers to run on, which this installer will"
say "create. Name it whatever you like - it only has to match container.network"
say "in each confined runner's config.yaml."
say
say "A runner configured for host networking (container.network: host) needs"
say "no job network - its jobs are in the host's own namespace, so no bridge"
say "sits in front of them and the rules below never apply to those jobs. If"
say "you have such a runner, the egress it gets is the host's own: give that"
say "machine a firewall of its own, or treat it as one you are willing to lose."
say "Set this up for the runners that do use a bridge, and skip it for those."
say

ask network "Job network name (e.g. dejima-ci)" "$(cfg_get network)"
: "${network:=dejima-ci}"
say

# Derived, not asked. Docker takes the first usable address of the subnet as
# the gateway, and the bridge is whatever name we give at creation - so two
# more prompts would only be two more chances for the answers to disagree
# with reality.
valid_cidr() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    local o=("${BASH_REMATCH[@]:1:4}") pfx="${BASH_REMATCH[5]}"
    for n in "${o[@]}"; do [ "$n" -le 255 ] || return 1; done
    [ "$pfx" -ge 8 ] && [ "$pfx" -le 30 ]
}
is_private() {
    [[ "$1" =~ ^10\. ]] && return 0
    [[ "$1" =~ ^192\.168\. ]] && return 0
    [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
    return 1
}

# Docker decides the gateway, so ask it first - but do not stake the install on
# one template expression. When a network is created with --subnet and no
# explicit --gateway, some daemons record no Gateway in IPAM.Config at all and
# only ever put the address on the bridge. Reading it back is right; reading it
# back from exactly one place is not.
#
# Sets: gateway, gw_src. Requires: $1 network, $2 bridge, $3 subnet.
read_gateway() {
    gateway=$(docker network inspect "$1" \
        -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)
    gw_src="docker"
    if [ -z "$gateway" ] && [ -n "$2" ]; then
        # The address actually on the bridge - as true as Docker's answer, and
        # true for the same reason: it is what containers route to.
        gateway=$(ip -4 -o addr show "$2" 2>/dev/null \
            | awk '{print $4}' | cut -d/ -f1 | head -1)
        gw_src="bridge $2"
    fi
    if [ -z "$gateway" ] && [ -n "$3" ]; then
        # Last resort: the subnet's first usable address, which is what Docker
        # picks when nothing says otherwise.
        IFS=./ read -r o1 o2 o3 o4 _pfx <<< "$3"
        gateway="$o1.$o2.$o3.$((o4 + 1))"
        gw_src="derived from $3"
    fi
    [ -n "$gateway" ]
}

if docker network inspect "$network" >/dev/null 2>&1; then
    # Already there: read what it actually is rather than asking and hoping.
    subnet=$(docker network inspect "$network" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    bridge=$(docker network inspect "$network" \
        -f '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || true)
    if [ -z "$bridge" ]; then
        nid=$(docker network inspect "$network" -f '{{.Id}}' 2>/dev/null || true)
        bridge="br-${nid:0:12}"
        say "  NOTE: $network was created without a fixed bridge name, so Docker"
        say "  generated $bridge. That works, but it changes if the network is ever"
        say "  recreated - and the firewall rules would then match nothing."
        say
    fi
    read_gateway "$network" "$bridge" "$subnet" \
        || die "$network exists but its gateway cannot be determined by any means"
    say "  $network already exists:"
    say "    subnet   $subnet"
    say "    gateway  $gateway   ($gw_src - the resolver listens here)"
    say "    bridge   $bridge"
    say
    say "  Of these, only the NAME goes in a runner's config (container.network),"
    say "  and the gateway goes in its --dns. The bridge is used by the firewall"
    say "  rules here and appears in no runner configuration."
else
    say "Its subnet. Must be PRIVATE - dnsmasq's stop-dns-rebind is keyed on the"
    say "private ranges, so a reserved-but-not-private subnet is one that check"
    say "silently does not cover. Pick one outside Docker's default pool"
    say "(172.17-172.31, 192.168.x) so an unrelated network cannot collide."
    say
    while :; do
        ask subnet "Subnet in CIDR form (e.g. 10.89.0.0/24)" "${subnet:-$(cfg_get subnet)}"
        : "${subnet:=10.89.0.0/24}"
        valid_cidr "$subnet" || { say "  not a CIDR block - it needs the form 10.89.0.0/24"; subnet=""; continue; }
        is_private "$subnet" || { say "  $subnet is not a private range - use 10.x, 172.16-31.x or 192.168.x"; subnet=""; continue; }
        break
    done


    # Interface names are capped at 15 characters by the kernel.
    bridge="${network}0"
    if [ ${#bridge} -gt 15 ]; then
        bridge="${bridge:0:15}"
        say "  NOTE: bridge name truncated to $bridge (interface names cap at 15)."
    fi

    say
    docker network create \
        --opt com.docker.network.bridge.name="$bridge" \
        --subnet "$subnet" "$network" >/dev/null \
        || die "could not create the network - is $subnet already in use? (docker network ls)"

    read_gateway "$network" "$bridge" "$subnet" \
        || die "created $network but its gateway cannot be determined by any means"

    say "  created    docker network $network"
    say "    subnet   $subnet"
    say "    gateway  $gateway   ($gw_src - the resolver listens here)"
    say "    bridge   $bridge"
    say
    say "  Only the NAME goes in a runner's config (container.network), and the"
    say "  gateway goes in its --dns. The bridge is what the firewall rules match"
    say "  on and appears in no runner configuration - nothing to copy."
fi
say

# --- forge ------------------------------------------------------------------
existing_api="$(cfg_get forge_api)"
default_instance="${existing_api%/api/v1}"
ask instance "Forge URL (e.g. https://gitea.example.com)" "$default_instance"
[ -n "$instance" ] || die "a forge URL is required"
instance="${instance%/}"
case "$instance" in
    */api/v1) forge_api="$instance" ;;
    *)        forge_api="$instance/api/v1" ;;
esac
say "  API root: $forge_api"
say

# --- upstream resolver ------------------------------------------------------
say "The upstream resolver is the one dnsmasq forwards ALLOWED queries to -"
say "the resolver that actually knows the answers. It is NOT the dnsmasq this"
say "configures, and NOT the job bridge gateway. It must be able to resolve"
say "your forge, so if that name is internal this has to be your internal DNS."
existing_upstream="$(cfg_get upstream)"
# Detection is a guess and has to be checked. resolvectl reports the first
# server it lists, which on a host with several - or with a local stub in
# front - can be one that does not actually answer. The host still resolves,
# because it falls through to another; dnsmasq points at exactly one and gets
# silence. That surfaces as every job failing at apt with "Temporary failure
# resolving", four layers away from the setting that caused it.
upstream_answers() {
    python3 - "$1" "$2" <<'PROBE'
import socket, struct, sys
q = b''.join(bytes([len(p)]) + p.encode() for p in sys.argv[2].split('.')) + b'\x00'
pkt = struct.pack('>HHHHHH', 0x5a5a, 0x0100, 1, 0, 0, 0) + q + struct.pack('>HH', 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
try:
    s.sendto(pkt, (sys.argv[1], 53))
    d, _ = s.recvfrom(512)
except OSError:
    sys.exit(1)
sys.exit(0 if (d[3] & 0xf) == 0 and struct.unpack('>H', d[6:8])[0] > 0 else 1)
PROBE
}

# The forge, because that is the name an upstream most plausibly cannot
# resolve: a public resolver handles deb.debian.org and would pass this check
# while leaving every job unable to reach the forge it checks out from.
probe_name="${instance#*://}"; probe_name="${probe_name%%/*}"; probe_name="${probe_name%%:*}"
: "${probe_name:=deb.debian.org}"

while :; do
    ask upstream "Upstream resolver address" "${existing_upstream:-$(detect_upstream)}"
    [ -n "$upstream" ] || die "an upstream resolver is required"
    if ! command -v python3 >/dev/null 2>&1; then
        say "  (python3 absent - cannot check that $upstream answers; verify by hand)"
        break
    fi
    if upstream_answers "$upstream" "$probe_name"; then
        say "  $upstream resolves $probe_name - good."
        break
    fi
    say
    say "  $upstream did not answer a query for $probe_name."
    say
    say "  This host resolving names is not the same thing: it may be using a"
    say "  different server, or a local stub that falls through to one. dnsmasq"
    say "  will point at this address and nothing else, so if it is silent every"
    say "  job fails at apt with 'Temporary failure resolving' and nothing names"
    say "  this setting."
    say
    say "  Servers this host has configured:"
    { resolvectl status 2>/dev/null | sed -n 's/.*DNS Servers: */    /p'
      sed -n 's/^nameserver/    /p' /etc/resolv.conf 2>/dev/null; } | sort -u >&2
    say
    ask retry_upstream "Try a different address? (Y/n)" "y"
    case "${retry_upstream,,}" in
        n|no) say "  continuing with $upstream - fix it before expecting jobs to resolve"; break ;;
    esac
    existing_upstream=""
done
case "$upstream" in
    127.0.0.53|127.0.0.1|::1)
        say
        say "  NOTE: $upstream is a local stub. That usually works, but it means the"
        say "  allowlist depends on whatever that stub forwards to. Prefer the real"
        say "  upstream if you know it." ;;
esac
say

# --- token ------------------------------------------------------------------
if [ -s "$TOKEN_FILE" ]; then
    say "A forge token is already installed at $TOKEN_FILE."
    ask replace_token "Replace it? (y/N)" "n"
else
    replace_token=y
    say "A forge token is needed. Read access only - this program only ever GETs"
    say "one file per repository, and a token that can do more is a token handed"
    say "to a machine that runs untrusted code."
fi
if [ "${replace_token,,}" = y ] || [ "${replace_token,,}" = yes ]; then
    token=""
    if [ "$NONINTERACTIVE" -eq 0 ]; then
        printf 'Forge token (not echoed): ' >&2
        IFS= read -rs token </dev/tty || true
        printf '\n' >&2
    fi
    if [ -n "$token" ]; then
        install -d -m 0750 "$CONF_DIR"
        printf '%s\n' "$token" > "$TOKEN_FILE.new"
        chmod 600 "$TOKEN_FILE.new"
        mv "$TOKEN_FILE.new" "$TOKEN_FILE"
        say "  written    $TOKEN_FILE"
        unset token
    elif [ ! -s "$TOKEN_FILE" ]; then
        install -d -m 0750 "$CONF_DIR"
        : > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
        say "  NOTE: no token supplied. Write one into $TOKEN_FILE before this runs."
    fi
fi
say

# --- repositories -----------------------------------------------------------
say "Repositories whose main branch may widen this runner's allowlist."
say "Adding one trusts that repository's main branch. One owner/repo per line,"
say "blank line to finish."
existing_repos=""
[ -r "$REPOS_FILE" ] && existing_repos="$(grep -vE '^\s*(#|$)' "$REPOS_FILE" || true)"
if [ -n "$existing_repos" ]; then
    say "Currently:"; sed 's/^/  /' <<< "$existing_repos" >&2
    ask keep_repos "Keep this list? (Y/n)" "y"
else
    keep_repos=n
fi
if [ "${keep_repos,,}" = n ] || [ "${keep_repos,,}" = no ]; then
    repos=""
    if [ "$NONINTERACTIVE" -eq 0 ]; then
        while :; do
            ask one "  owner/repo" ""
            [ -n "$one" ] || break
            repos="${repos:+$repos$'\n'}$one"
        done
    fi
    [ -n "$repos" ] || repos="$existing_repos"
    write_if_changed "$REPOS_FILE" 0640 "$repos"
else
    write_if_changed "$REPOS_FILE" 0640 "$existing_repos"
fi
say

# --- base domains -----------------------------------------------------------
say "Names allowed regardless of any project declaration. Keep this short, and"
say "narrower than dejima's built-in domains - a name judged reasonable for a"
say "firewalled container is a different proposition on a host on your network."
forge_host="${instance#*://}"; forge_host="${forge_host%%/*}"; forge_host="${forge_host%%:*}"
existing_base=""
[ -r "$BASE_FILE" ] && existing_base="$(grep -vE '^\s*(#|$)' "$BASE_FILE" || true)"
default_base="${existing_base:-$forge_host$'\n'deb.debian.org}"
if [ -n "$existing_base" ]; then
    say "Currently:"; sed 's/^/  /' <<< "$existing_base" >&2
    ask keep_base "Keep this list? (Y/n)" "y"
else
    say "Suggested:"; sed 's/^/  /' <<< "$default_base" >&2
    ask keep_base "Use this list? (Y/n)" "y"
fi
if [ "${keep_base,,}" = n ] || [ "${keep_base,,}" = no ]; then
    base=""
    if [ "$NONINTERACTIVE" -eq 0 ]; then
        say "One name per line, blank line to finish."
        while :; do
            ask one "  domain" ""
            [ -n "$one" ] || break
            base="${base:+$base$'\n'}$one"
        done
    fi
    [ -n "$base" ] || base="$default_base"
else
    base="$default_base"
fi
write_if_changed "$BASE_FILE" 0640 "$base"
say

# --- remaining settings -----------------------------------------------------
ipset="$(cfg_get ipset)"; : "${ipset:=ci-allow}"
ask out    "Generated allowlist path" "$(cfg_get out)"
ask ref    "Branch treated as operator-approved" "$(cfg_get ref)"
ask reload "Command that reloads the resolver" "$(cfg_get reload)"
: "${out:=/etc/dnsmasq.d/ci-allow.conf}"
: "${ref:=main}"
: "${reload:=systemctl reload dnsmasq}"
say

# --- write ------------------------------------------------------------------
write_if_changed "$CONFIG" 0640 "# Written by $PROG. Re-run it to change a value.
network = $network
bridge = $bridge
gateway = $gateway
subnet = $subnet
ipset = $ipset
forge_api = $forge_api
token_file = $TOKEN_FILE
repos_file = $REPOS_FILE
base_file = $BASE_FILE
upstream = $upstream
out = $out
ref = $ref
reload = $reload"

for prog in dejima-ci-allowlist dejima-ci-firewall dejima-ci-runners; do
    if cmp -s "$SRC/bin/$prog" "$BIN_DIR/$prog" 2>/dev/null; then
        say "  unchanged  $BIN_DIR/$prog"
    else
        install -m 0755 "$SRC/bin/$prog" "$BIN_DIR/$prog"
        say "  installed  $BIN_DIR/$prog"
    fi
done

# The templates dejima-ci-runners renders. Installed rather than read from the
# checkout, because it is installed too and has to keep working once whatever
# clone it came from is gone.
if writable "$TEMPLATE_DIR"; then
    for tpl in "$SRC"/examples/*; do
        [ -f "$tpl" ] || continue
        if cmp -s "$tpl" "$TEMPLATE_DIR/${tpl##*/}" 2>/dev/null; then
            say "  unchanged  $TEMPLATE_DIR/${tpl##*/}"
        else
            install -m 0644 "$tpl" "$TEMPLATE_DIR/${tpl##*/}"
            say "  installed  $TEMPLATE_DIR/${tpl##*/}"
        fi
    done
else
    say "  skipped    $TEMPLATE_DIR (not writable) - dejima-ci-runners will read"
    say "             them from this checkout instead"
fi

# The resolver's static half. Its generated half - the server= lines - is
# written by dejima-ci-allowlist from origin/main, into a separate file in the
# same directory. Keeping them apart is what stops a hand-edit drifting from
# the list that is actually derived from a branch you control.
forge_host="${instance#*://}"; forge_host="${forge_host%%/*}"; forge_host="${forge_host%%:*}"
write_if_changed "$DNSMASQ_DIR/dejima-ci.conf" 0644 "# Written by $PROG. The allowed names live in the file
# dejima-ci-allowlist renders; do not add server= lines here.
listen-address=$gateway
# bind-dynamic, not bind-interfaces: a Docker bridge is recreated whenever its
# network is, and bind-interfaces would leave dnsmasq holding a socket on a
# device that no longer exists - bound according to ss, answering nothing.
bind-dynamic
no-hosts
no-resolv
ipset=/#/$ipset
stop-dns-rebind
rebind-domain-ok=/$forge_host/"

if [ "$INSTALL_UNITS" -eq 1 ]; then
    for unit in dejima-ci-allowlist.service dejima-ci-allowlist.timer dejima-ci-firewall.service; do
        write_if_changed "$UNIT_DIR/$unit" 0644 "$(cat "$SRC/systemd/$unit")"
    done
else
    say "  skipped    $UNIT_DIR (not writable) - install the units by hand"
fi

say
if [ "$INSTALL_UNITS" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    ask enable_timer "Enable and start the refresh timer? (Y/n)" "y"
    if [ "${enable_timer,,}" != n ] && [ "${enable_timer,,}" != no ]; then
        systemctl enable --now dejima-ci-allowlist.timer
        say "  timer enabled"
    fi
    # PartOf + WantedBy on docker.service, so the rules are reapplied whenever
    # Docker starts. Docker recreates its own chains on every start and
    # DOCKER-USER comes back empty, so "apply them once" is not an
    # instruction that stays true.
    ask enable_fw "Enable the firewall unit (reapplies rules on every Docker start)? (Y/n)" "y"
    if [ "${enable_fw,,}" != n ] && [ "${enable_fw,,}" != no ]; then
        systemctl enable --now dejima-ci-firewall.service
        say "  firewall unit enabled"
    fi
    # After the network, always. Even with bind-dynamic the config was just
    # rewritten, and if the bridge was created moments ago this is what picks
    # it up.
    systemctl restart dnsmasq 2>/dev/null || say "  NOTE: could not restart dnsmasq - do it by hand"
fi

say
say "=============================================================="
say " The runners"
say "=============================================================="
say
say "Everything above is the machinery a runner's jobs sit behind. Nothing is"
say "behind it yet, because no runner is configured on this host."
say
say "This used to be a list of five things to copy into a runner's config by"
say "hand, and every one of them was a value that had to match a value here:"
say "container.network with $network, --dns with $gateway,"
say "CONFIG_FILE with the path the compose file mounts to. Getting any of them"
say "wrong produces a runner that starts and runs jobs and filters nothing."
say
say "$BIN_DIR/dejima-ci-runners writes both files from what is in"
say "$CONFIG, so there is nothing to keep in step by hand."
say

run_runners=n
if [ "$NONINTERACTIVE" -eq 0 ]; then
    ask run_runners "Set up the runners now? (Y/n)" "y"
fi
if [ "${run_runners,,}" != n ] && [ "${run_runners,,}" != no ]; then
    say
    # Not exec'd and not fatal: everything above this point is installed and
    # correct, and a runner that needs a second attempt should not read as the
    # allowlist having failed.
    "$BIN_DIR/dejima-ci-runners" --role confined || \
        say "  runner setup did not finish - re-run $BIN_DIR/dejima-ci-runners --role confined"
else
    say "Skipped. When you are ready:"
    say
    say "  $BIN_DIR/dejima-ci-runners --role confined"
    say
    say "It asks for a label and a count, takes the network and resolver from"
    say "$CONFIG, and tells you which page of your forge mints"
    say "the registration token."
fi

say
say "Then verify from inside a job rather than from this host. A runner that"
say "grants the socket looks identical to one that does not, from out here and"
say "from your forge's UI. dejima ships test/ci-runner.bats for exactly this."
say "If the DNS checks pass while the egress checks fail, the resolver is fine"
say "and the firewall is not:"
say
say "  $BIN_DIR/dejima-ci-firewall && iptables -S DOCKER-USER"
say
say "A runner using host networking is not covered by any of this: its jobs"
say "are in the host's namespace, no bridge is in front of them, and the rules"
say "installed here do not filter them. That is the privileged tier, and it"
say "belongs on its own machine - see the README."
say
say "Files this installer owns, for later reference:"
say "  config       $CONFIG"
say "  allowlist    $out            (generated - do not hand-edit)"
say "  resolver     $DNSMASQ_DIR/dejima-ci.conf"
say "  firewall     $BIN_DIR/dejima-ci-firewall (unit: dejima-ci-firewall.service)"
say
say "=============================================================="
say
say "Checking the configuration..."
rc=0
"$BIN_DIR/dejima-ci-allowlist" check --config "$CONFIG" || rc=$?
case "$rc" in
    0) say "Up to date." ;;
    1) say; say "There is a pending change, shown above. Apply it with:"
       say "  $BIN_DIR/dejima-ci-allowlist render" ;;
    *) say; say "The configuration is not usable yet - the problems are listed above."
       say "Re-run this installer to fix them."; exit "$rc" ;;
esac
