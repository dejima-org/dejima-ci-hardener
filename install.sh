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
SHARE_DIR=${SHARE_DIR:-/usr/local/share/dejima-ci}
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

# ask, defaulting to the config file's value and falling back to a built-in
# when there is none.
#
# The fallback is passed to ask rather than applied to its answer afterwards,
# and that is the whole point: ask only prints [brackets] when it is given a
# non-empty default, so a fallback applied after the fact is invisible. On a
# first install cfg_get returns nothing for every one of these, so each prompt
# appeared bare - asking for a path, a branch and a shell command with no
# indication that pressing Enter would produce a working answer, or what it
# would be.
ask_cfg() {
    local __var="$1" prompt="$2" key="$3" fallback="$4" def
    def="$(cfg_get "$key")"
    [ -n "$def" ] || def="$fallback"
    ask "$__var" "$prompt" "$def"
}

# Collect a list, with a way to take an entry back and a look at the whole of
# it before it is written.
#
# Entry used to be one-way: a mistyped line was accepted in silence, and the
# only ways out were to live with it or abandon the run and start the installer
# again. Neither is proportionate to a typo, and the list this reads decides
# which repositories may widen a runner's allowlist - somewhere a wrong entry
# should be easy to notice and cheap to undo.
read_list() {   # read_list VAR PROMPT VALIDATOR
    local __var="$1" prompt="$2" validate="$3" acc="" one ok removed
    while :; do
        acc=""
        say "One per line. '-' takes back the last one. Blank line to finish."
        while :; do
            ask one "  $prompt" ""
            case "$one" in
                "") break ;;
                -)  if [ -n "$acc" ]; then
                        removed="${acc##*$'\n'}"
                        if [ "$removed" = "$acc" ]; then acc=""; else acc="${acc%$'\n'*}"; fi
                        say "    took back $removed"
                    else
                        say "    nothing to take back"
                    fi
                    continue ;;
            esac
            "$validate" "$one" || continue
            acc="${acc:+$acc$'\n'}$one"
        done
        if [ -z "$acc" ]; then printf -v "$__var" '%s' ""; return 0; fi
        say
        say "  That is:"
        sed 's/^/    /' <<< "$acc" >&2
        say
        ask ok "Is that right? (Y/n)" "y"
        case "${ok,,}" in n|no) say; continue ;; esac
        printf -v "$__var" '%s' "$acc"
        return 0
    done
}

# Checked on the way in, so a malformed line is rejected while the person who
# typed it is still looking at it. Neither of these can tell a real repository
# from an imagined one - only the forge can - but both catch the shape.
valid_repo_entry() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && return 0
    say "    not an owner/repo - e.g. acme/widget"
    return 1
}
valid_domain_entry() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] && return 0
    say "    not a domain name - e.g. deb.debian.org"
    return 1
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

On a host built for this, run the bootstrap instead of this - it installs
these, hardens the host, and then runs this script itself:

  sudo $SRC/bin/dejima-ci-bootstrap --role confined --mgmt <your-ip>

Running this on its own is for changing a setting afterwards, on a host that
already has what it needs.

If you are deliberately not using the bootstrap, install them yourself. Note
that dejima-ci-runners will want Docker Compose v2 as well, and compose has no
single package name that works across releases: docker-compose-v2 does not
exist before trixie, and the fallbacks are backports and then Docker's own
repository. This installer fetches nothing on your behalf - adding a Docker
daemon to someone's machine is not a thing to do without being asked.

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

ask_cfg network "Job network name" network dejima-ci
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
        ask_cfg subnet "Subnet in CIDR form" subnet 10.89.0.0/24
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
    say
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
    # resolvectl guarded by command -v, and the whole thing allowed to fail.
    # Without the guard this aborted the installer outright on any host that
    # does not have it - which is most of them, including a VM built by
    # proxmox/README.md. `set -o pipefail` makes the inner pipeline return the
    # 127 from a missing resolvectl, `set -e` acts on it, and the run ends on
    # exit 127 with no message, immediately after printing this heading. A
    # diagnostic that kills the program it is diagnosing is worse than no
    # diagnostic.
    {
        if command -v resolvectl >/dev/null 2>&1; then
            resolvectl status 2>/dev/null | sed -n 's/.*DNS Servers: */    /p' || true
        fi
        sed -n 's/^nameserver/    /p' /etc/resolv.conf 2>/dev/null || true
    } | sort -u >&2 || true
    say

    # Non-interactive cannot answer, and the default it would take used to be
    # "retry" - which re-offered the same detected address, failed the same
    # probe, and looped forever with no terminal to say so on.
    if [ "$NONINTERACTIVE" -eq 1 ]; then
        say "  continuing with $upstream - fix it before expecting jobs to resolve"
        break
    fi
    # Defaults to no, so Enter moves on. Defaulting to yes meant that pressing
    # Enter - which this installer tells you to do to keep the value shown -
    # asked the same question about the same address indefinitely.
    ask retry_upstream "Try a different address? (y/N)" "n"
    case "${retry_upstream,,}" in
        y|yes) existing_upstream="" ;;
        *) say "  continuing with $upstream - fix it before expecting jobs to resolve"; break ;;
    esac
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
    say
    ask replace_token "Replace it? (y/N)" "n"
else
    replace_token=y
    say "A forge API token is needed, so this can read .dejima/allowed-domains"
    say "from the main branch of each repository listed below."
    say
    say "Create one here:"
    say "  $instance/user/settings/applications"
    say
    say "Give it read access to repository contents and nothing else. This only"
    say "ever GETs one file per repository, and a token that can do more is a"
    say "token handed to a machine that runs untrusted code."
    say
    say "THIS IS NOT THE RUNNER REGISTRATION TOKEN. That is a different string"
    say "from a different page - Actions -> Runners - used once to register a"
    say "runner, and the API rejects it with a 401. dejima-ci-runners asks for"
    say "that one separately, later. The two are easy to swap and the only"
    say "symptom is this program failing to read anything."
fi
if [ "${replace_token,,}" = y ] || [ "${replace_token,,}" = yes ]; then
    token=""
    if [ "$NONINTERACTIVE" -eq 0 ]; then
        say
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
# KEEP, ADD or REPLACE, because the two-way version made adding one project
# mean retyping every project already there, from memory, in a prompt with no
# way back. That is also the wrong tool for the job: adding a repository does
# not need the installer at all now.
if [ -n "$existing_repos" ]; then
    say "Currently:"; sed 's/^/  /' <<< "$existing_repos" >&2
    say
    say "Adding one does not need this installer:"
    say "  sudo $BIN_DIR/dejima-ci-allowlist repos add owner/repo"
    say
    ask keep_repos "[K]eep this list, [a]dd to it, or [r]eplace it?" "k"
else
    keep_repos=r
fi
case "${keep_repos,,}" in
    a|add)
        repos=""
        [ "$NONINTERACTIVE" -eq 0 ] && read_list repos "owner/repo to add" valid_repo_entry
        if [ -n "$repos" ]; then
            repos=$(printf '%s\n%s\n' "$existing_repos" "$repos" | grep -v '^$' | sort -u)
        else
            repos="$existing_repos"
        fi
        write_if_changed "$REPOS_FILE" 0640 "$repos" ;;
    r|replace|n|no)
        repos=""
        [ "$NONINTERACTIVE" -eq 0 ] && read_list repos "owner/repo" valid_repo_entry
        [ -n "$repos" ] || repos="$existing_repos"
        write_if_changed "$REPOS_FILE" 0640 "$repos" ;;
    *)
        write_if_changed "$REPOS_FILE" 0640 "$existing_repos" ;;
esac
say

# --- does the forge actually accept that token? -----------------------------
# The token is the one setting here that cannot be judged by looking at it. A
# wrong one and a right one are both a non-empty 0600 file; only the forge can
# tell them apart, and it is asked here rather than at the end so that a
# rejected token is fixed while it is still the thing you are doing - not after
# the units are enabled and the runners are registered and running.
#
# Probed against the first configured repository, using the same request the
# allowlist will make. 200 and 404 both mean the token authenticated: 404 is a
# repository with no declaration, which is ordinary.
token_status() {  # token_status TOKEN REPO -> HTTP status, or 000 if unreachable
    curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
        -H "Authorization: token $1" \
        "$forge_api/repos/$2/raw/.dejima/allowed-domains?ref=main" 2>/dev/null \
        || printf '000'
}

probe_repo=$(grep -vE '^\s*(#|$)' "$REPOS_FILE" 2>/dev/null | head -1 || true)
if command -v curl >/dev/null 2>&1 && [ -s "$TOKEN_FILE" ] && [ -n "$probe_repo" ]; then
    while :; do
        status=$(token_status "$(cat "$TOKEN_FILE")" "$probe_repo")
        case "$status" in
            200|404) say "  the forge accepted the token."; break ;;
        esac
        say
        case "$status" in
            401) say "  The forge REJECTED the token (401)."
                 say
                 say "  Check first that it is an API token. A RUNNER REGISTRATION token"
                 say "  - from Actions -> Runners, the one dejima-ci-runners asks for -"
                 say "  is a different string that the API rejects exactly like this, and"
                 say "  the two are asked for minutes apart by this same tool."
                 say
                 say "  An API token comes from:"
                 say "    $instance/user/settings/applications"
                 say
                 say "  Otherwise it is present but wrong: mistyped or truncated when"
                 say "  pasted, revoked, or expired." ;;
            403) say "  The forge accepted the token but refused the read (403)."
                 say "  It authenticates, so this is scope rather than identity - a Gitea"
                 say "  token created with no scopes selected reads nothing. It needs read"
                 say "  access to repository contents, and nothing more." ;;
            30[1278])
                 say "  The forge redirected ($status) for $probe_repo, which is"
                 say "  about that repository rather than about the token: it has"
                 say "  been renamed or moved to another owner."
                 say
                 say "  Fix the entry in $REPOS_FILE - the rest of this"
                 say "  run is unaffected, and re-running this installer or"
                 say "  'sudo $BIN_DIR/dejima-ci-allowlist render' picks it up." ;;
            000) say "  Could not reach $forge_api to check the token."
                 say "  That is the network or the forge, not the token itself." ;;
            *)   say "  The forge answered $status when checking the token against"
                 say "  $probe_repo." ;;
        esac
        say
        say "  Until this is fixed the allowlist cannot be rendered, and job"
        say "  containers get a resolver that answers for nothing."
        say
        if [ "$NONINTERACTIVE" -eq 1 ]; then
            say "  Continuing - fix the token and run: sudo $BIN_DIR/dejima-ci-allowlist render"
            break
        fi
        case "$status" in
            30[1278]) say "  Continuing. Fix $REPOS_FILE, then run:"
                      say "    sudo $BIN_DIR/dejima-ci-allowlist render"
                      break ;;
        esac
        ask retry_token "Enter a different token now? (Y/n)" "y"
        case "${retry_token,,}" in
            n|no) say "  Continuing. Fix $TOKEN_FILE, then run:"
                  say "    $BIN_DIR/dejima-ci-allowlist render"
                  break ;;
        esac
        printf 'Forge token (not echoed): ' >&2
        IFS= read -rs newtok </dev/tty || true
        printf '\n' >&2
        if [ -z "$newtok" ]; then
            say "  Nothing entered - leaving the current token in place."
            break
        fi
        printf '%s\n' "$newtok" > "$TOKEN_FILE.new"
        chmod 600 "$TOKEN_FILE.new"
        mv "$TOKEN_FILE.new" "$TOKEN_FILE"
        unset newtok
        say "  written    $TOKEN_FILE"
    done
    say
fi

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
    say
    ask keep_base "Keep this list? (Y/n)" "y"
else
    say "Suggested:"; sed 's/^/  /' <<< "$default_base" >&2
    say
    ask keep_base "Use this list? (Y/n)" "y"
fi
if [ "${keep_base,,}" = n ] || [ "${keep_base,,}" = no ]; then
    base=""
    if [ "$NONINTERACTIVE" -eq 0 ]; then
        read_list base "domain" valid_domain_entry
    fi
    [ -n "$base" ] || base="$default_base"
else
    base="$default_base"
fi
write_if_changed "$BASE_FILE" 0640 "$base"
say

# --- remaining settings -----------------------------------------------------
ipset="$(cfg_get ipset)"; : "${ipset:=ci-allow}"
say "Where the generated allowlist goes, which branch is trusted, and how the"
say "resolver is reloaded. The defaults are right unless you have a reason."
say
ask_cfg out    "Generated allowlist path"           out    /etc/dnsmasq.d/ci-allow.conf
ask_cfg ref    "Branch treated as operator-approved" ref    main
ask_cfg reload "Command that reloads the resolver"   reload "systemctl reload dnsmasq"
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

for prog in dejima-ci-allowlist dejima-ci-firewall dejima-ci-runners dejima-ci-static-ip \
            dejima-ci-upgrade; do
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

# The upgrade notes, so an operator on a runner with no checkout can still read
# what an upgrade asks of them. The installed copy knows only the versions that
# existed when it ran, and dejima-ci-upgrade says so rather than reporting "up
# to date" about versions it has never heard of.
if writable "$SHARE_DIR/upgrades"; then
    for note in "$SRC"/upgrades/*.md; do
        [ -f "$note" ] || continue
        if cmp -s "$note" "$SHARE_DIR/upgrades/${note##*/}" 2>/dev/null; then
            say "  unchanged  $SHARE_DIR/upgrades/${note##*/}"
        else
            install -m 0644 "$note" "$SHARE_DIR/upgrades/${note##*/}"
            say "  installed  $SHARE_DIR/upgrades/${note##*/}"
        fi
    done
fi

# What this host is now at, guest-side, and which tier it is.
#
# Both are recorded rather than asked or detected. The version comes from the
# checkout's VERSION, so it records something this program just did. The tier is
# 'confined' by construction: install.sh does not run on a privileged host, and
# the whole point of that tier is that nothing here is installed there.
#
# THIS FILE IS INSIDE THE SNAPSHOT. On a runner that is correct rather than
# unfortunate - forget to re-snapshot after a guest-side upgrade and the marker
# rolls back alongside the change it was recording, so dejima-ci-upgrade goes
# back to reporting the upgrade as outstanding. It fails towards saying there is
# work to do.
version=$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null || true)
[ -n "$version" ] || die "no version in $SRC/VERSION - refusing to record an empty one"
{
    [ -r "$CONF_DIR/state" ] && grep -vE '^(guest_version|tier)=' "$CONF_DIR/state" || true
    printf 'guest_version=%s\ntier=confined\n' "$version"
} > "$CONF_DIR/state.new"
sort -o "$CONF_DIR/state.new" "$CONF_DIR/state.new"
chmod 0640 "$CONF_DIR/state.new"
mv "$CONF_DIR/state.new" "$CONF_DIR/state"
say "  recorded   $CONF_DIR/state (guest_version=$version, tier=confined)"

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
    # @@BIN_DIR@@ substituted rather than written into the units, because the
    # path was previously in two places and they disagreed: the units named
    # /usr/local/bin while this installs to /usr/local/sbin, so the timer's
    # service failed with 203/EXEC on every tick. Nothing said so - a timer
    # that never succeeds looks exactly like one that has nothing to do, and
    # the allowlist simply stopped being refreshed.
    for unit in dejima-ci-allowlist.service dejima-ci-allowlist.timer dejima-ci-firewall.service; do
        write_if_changed "$UNIT_DIR/$unit" 0644 \
            "$(sed "s|@@BIN_DIR@@|$BIN_DIR|g" "$SRC/systemd/$unit")"
    done

    # And checked, because a unit that names a program which is not there is
    # only visible as a failed start, long after this run has finished.
    for unit in dejima-ci-allowlist.service dejima-ci-firewall.service; do
        exe=$(sed -n 's|^ExecStart=\([^ ]*\).*|\1|p' "$UNIT_DIR/$unit" | head -1)
        [ -x "$exe" ] || die "$UNIT_DIR/$unit runs $exe, which is not executable.
That is this installer's own mistake rather than anything you did. The programs
are installed to $BIN_DIR; report the mismatch."
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
    say
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
# Asserted without checking, until a re-run said it on a host with runners
# already going. Re-running the installer to change one setting is the normal
# way to use it, so "no runner is configured" was most likely to be read by
# somebody it was false for - and it reads as the installer having undone
# something.
runner_user="${SUDO_USER:-$(id -un)}"
runner_home=$(getent passwd "$runner_user" | cut -d: -f6)
[ -n "$runner_home" ] || runner_home="$HOME"
existing_runners=$(find "$runner_home/runners" -mindepth 2 -maxdepth 2 \
                        -name docker-compose.yml 2>/dev/null | wc -l)

if [ "$existing_runners" -gt 0 ]; then
    say "Everything above is the machinery a runner's jobs sit behind, and this"
    say "host already has $existing_runners runner project(s). Nothing above has"
    say "changed them:"
    say
    # Read out here rather than left for the operator to go and find. Wanting
    # to know the count and the label of what is already running is the first
    # thing anybody does at this point, and cat'ing a compose file in another
    # terminal is not an answer this program should make them look for.
    while IFS= read -r proj; do
        d=$(dirname "$proj")
        n=$(grep -c '^ *container_name:' "$proj" 2>/dev/null || echo 0)
        l=$(sed -n 's|^ *- "\([^:]*\):docker://.*|\1|p' "$d/config.yaml" 2>/dev/null | head -1)
        net=$(sed -n 's|^ *network: *"\{0,1\}\([^"]*\)"\{0,1\} *$|\1|p' "$d/config.yaml" 2>/dev/null | head -1)
        say "  $(basename "$d"): $n runner(s), label ${l:-?}, network ${net:-?}"
        say "    $d"
    done < <(find "$runner_home/runners" -mindepth 2 -maxdepth 2 -name docker-compose.yml 2>/dev/null | sort)
else
    say "Everything above is the machinery a runner's jobs sit behind. Nothing is"
    say "behind it yet, because no runner is configured on this host."
fi
say
say "$BIN_DIR/dejima-ci-runners writes the compose project and the"
say "runner config together, taking the job network and the resolver address"
say "from $CONFIG. A runner whose container.network or"
say "--dns disagrees with what was set up here starts, accepts jobs, and"
say "filters nothing - so neither is left for you to copy across."
say

# DEFAULTS TO NO WHERE RUNNERS EXIST, and that is not a style choice.
#
# Re-running this installer to change one setting is the normal way to use it,
# and pressing enter through the questions is how it is meant to be re-run. On a
# host that already had two pools, enter here walked into generating a new one
# from built-in defaults - so the operator had to background the installer, read
# their count and label out of a compose file in another terminal, and come back
# to a prompt that had moved on. Answering the safe way should be the thing that
# happens when nobody answers.
run_runners=n
if [ "$NONINTERACTIVE" -eq 0 ]; then
    if [ "$existing_runners" -gt 0 ]; then
        say "Your existing runners are untouched either way. Say yes only to add"
        say "a pool, or to change one - the generator reads what is already in a"
        say "project directory and offers it back, so enter through its questions"
        say "reproduces that pool rather than replacing it."
        say
        ask run_runners "Set up or change a runner pool now? (y/N)" "n"
    else
        ask run_runners "Set up the runners now? (Y/n)" "y"
    fi
fi
if [ "${run_runners,,}" != n ] && [ "${run_runners,,}" != no ]; then
    say
    # Not exec'd and not fatal: everything above this point is installed and
    # correct, and a runner that needs a second attempt should not read as the
    # allowlist having failed.
    "$BIN_DIR/dejima-ci-runners" --role confined || \
        say "  runner setup did not finish - re-run: sudo $BIN_DIR/dejima-ci-runners --role confined"
else
    say "Skipped. When you are ready:"
    say
    say "  sudo $BIN_DIR/dejima-ci-runners --role confined"
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
say "  sudo $BIN_DIR/dejima-ci-firewall && sudo iptables -S DOCKER-USER"
say
say "A runner using host networking is not covered by any of this: its jobs"
say "are in the host's namespace, no bridge is in front of them, and the rules"
say "installed here do not filter them. That is the privileged tier, and it"
say "belongs on its own machine - see the README."
say
# Reachability, not just existence.
#
# Everything installs to /usr/local/sbin and every instruction in this
# repository reads `sudo dejima-ci-...`. That works only where sudoers sets a
# secure_path including sbin; without one, sudo inherits the caller's PATH, and
# Debian leaves every sbin directory off a non-root PATH. The result is a
# correct install whose documented commands all report "command not found",
# which reads as a broken install rather than as a PATH.
#
# This runs under sudo, so its own PATH is the one those later commands will
# get. Asking `command -v` here is therefore the real question rather than a
# proxy for it.
if [ "$(command -v dejima-ci-allowlist 2>/dev/null)" != "$BIN_DIR/dejima-ci-allowlist" ]; then
    say
    say "  NOTE: $BIN_DIR is not on the PATH sudo gives you here, so"
    say "  'sudo dejima-ci-allowlist ...' will not be found. Either use the full"
    say "  path, as $BIN_DIR/dejima-ci-allowlist, or add a secure_path to"
    say "  sudoers that includes it. Nothing about the install is wrong."
fi

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
       say "  sudo $BIN_DIR/dejima-ci-allowlist render" ;;
    *) say; say "The configuration is not usable yet - the problems are listed above."
       say "Re-run this installer to fix them."; exit "$rc" ;;
esac
