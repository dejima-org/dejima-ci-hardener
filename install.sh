#!/usr/bin/env bash
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
    install -d -m 0750 "$(dirname "$path")"
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
On Debian/Ubuntu: apt-get install ipset iptables dnsmasq
Without ipset the firewall cannot be applied, and a runner with no egress
policy looks exactly like one with."

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
say "in each ordinary runner's config.yaml."
say
say "The privileged runner needs none: its jobs run in the host network"
say "namespace, which is the grant they exist for."
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

if docker network inspect "$network" >/dev/null 2>&1; then
    # Already there: read what it actually is rather than asking and hoping.
    subnet=$(docker network inspect "$network" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    gateway=$(docker network inspect "$network" -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)
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
    say "  $network already exists:"
    say "    subnet   $subnet"
    say "    gateway  $gateway"
    say "    bridge   $bridge"
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

    # Read the gateway back rather than computing it. Docker decides it, and a
    # value derived here would be a second opinion that can differ - which for
    # the resolver's listen-address and the runner's --dns is the difference
    # between working and silently not.
    gateway=$(docker network inspect "$network" \
        -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)
    [ -n "$gateway" ] || die "created $network but could not read its gateway back"

    say "  created    docker network $network"
    say "    subnet   $subnet"
    say "    gateway  $gateway   (Docker's, read back - the resolver listens here)"
    say "    bridge   $bridge   (fixed, so the firewall rules can name it)"
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
ask upstream "Upstream resolver address" "${existing_upstream:-$(detect_upstream)}"
[ -n "$upstream" ] || die "an upstream resolver is required"
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

for prog in dejima-ci-allowlist dejima-ci-firewall; do
    if cmp -s "$SRC/bin/$prog" "$BIN_DIR/$prog" 2>/dev/null; then
        say "  unchanged  $BIN_DIR/$prog"
    else
        install -m 0755 "$SRC/bin/$prog" "$BIN_DIR/$prog"
        say "  installed  $BIN_DIR/$prog"
    fi
done

# The resolver's static half. Its generated half - the server= lines - is
# written by dejima-ci-allowlist from origin/main, into a separate file in the
# same directory. Keeping them apart is what stops a hand-edit drifting from
# the list that is actually derived from a branch you control.
forge_host="${instance#*://}"; forge_host="${forge_host%%/*}"; forge_host="${forge_host%%:*}"
write_if_changed /etc/dnsmasq.d/dejima-ci.conf 0644 "# Written by $PROG. The allowed names live in the file
# dejima-ci-allowlist renders; do not add server= lines here.
listen-address=$gateway
bind-interfaces
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
    systemctl restart dnsmasq 2>/dev/null || say "  NOTE: could not restart dnsmasq - do it by hand"
fi

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
