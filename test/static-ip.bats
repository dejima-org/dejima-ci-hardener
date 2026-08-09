#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Brad Anderson
#
# Drives bin/dejima-ci-static-ip against a stubbed ip/ifup/systemctl and
# fixture copies of the two files it edits.
#
# What is worth testing here is not that it can write a stanza. It is that the
# values it writes are the ones the host already has - a conversion that
# renumbers anything is one that costs you the machine over SSH - and that
# every way of producing an unusable configuration ends with the original files
# back in place. A host whose /etc/network/interfaces does not parse, or whose
# resolv.conf names no server, does not fail now: it fails at its next start,
# with nobody watching and nothing pointing here.

setup() {
    BIN="${BATS_TEST_DIRNAME}/../bin/dejima-ci-static-ip"
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin"

    cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
  "route show default")
      [ -n "${STUB_NO_ROUTE:-}" ] && exit 0
      echo "default via 192.0.2.1 dev ens18 onlink" ;;
  *"addr show dev ens18"*)
      [ -n "${STUB_NO_ADDR:-}" ] && exit 0
      echo "2: ens18    inet 192.0.2.58/24 brd 192.0.2.255 scope global ens18" ;;
esac
EOF
    # ifup --no-act: the syntax check. STUB_IFUP_FAIL makes it reject.
    cat > "$T/bin/ifup" <<'EOF'
#!/bin/sh
[ -n "${STUB_IFUP_FAIL:-}" ] && exit 1
exit 0
EOF
    # No DHCP client units by default.
    printf '#!/bin/sh\nexit 1\n' > "$T/bin/systemctl"
    chmod +x "$T/bin"/*
    export PATH="$T/bin:$PATH"

    export IFACES="$T/interfaces" RESOLV="$T/resolv" RESOLV_HEAD="$T/resolv.head"
    cat > "$IFACES" <<'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

allow-hotplug ens18
iface ens18 inet dhcp
EOF
    printf 'nameserver 192.0.2.11\n' > "$RESOLV"
}

run_tool() { run bash "$BIN" --non-interactive "$@"; }

@test "writes the address the interface already has, not a new one" {
    run_tool
    [ "$status" -eq 0 ]
    grep -q '^    address 192.0.2.58/24$' "$IFACES"
    grep -q '^    gateway 192.0.2.1$' "$IFACES"
}

@test "the dhcp stanza becomes static, and comes up at boot" {
    run_tool
    grep -q '^iface ens18 inet static$' "$IFACES"
    ! grep -q 'inet dhcp' "$IFACES"
    # auto, not allow-hotplug: a machine restarted on a schedule needs its
    # network back as part of boot rather than when a device is enumerated.
    grep -q '^auto ens18$' "$IFACES"
    ! grep -q 'allow-hotplug' "$IFACES"
}

@test "other interfaces are left exactly as they were" {
    run_tool
    grep -q '^auto lo$' "$IFACES"
    grep -q '^iface lo inet loopback$' "$IFACES"
    grep -q '^source /etc/network/interfaces.d/\*$' "$IFACES"
}

@test "the resolver is written to both the file and the head file" {
    run_tool
    grep -q '^nameserver 192.0.2.11$' "$RESOLV"
    grep -q '^nameserver 192.0.2.11$' "$RESOLV_HEAD"
}

@test "several nameservers all survive" {
    printf 'nameserver 192.0.2.11\nnameserver 192.0.2.12\n' > "$RESOLV"
    run_tool
    grep -q '^nameserver 192.0.2.11$' "$RESOLV"
    grep -q '^nameserver 192.0.2.12$' "$RESOLV"
}

@test "running it twice changes nothing the second time" {
    run_tool
    [ "$status" -eq 0 ]
    cp "$IFACES" "$T/first"
    run_tool
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured statically"* ]]
    cmp "$T/first" "$IFACES"
}

@test "a host with no resolver is refused rather than pinned without one" {
    # The failure this prevents is silent and delayed: the configuration is
    # written, the running host keeps resolving on what it already had, and the
    # next start produces a machine that resolves nothing.
    : > "$RESOLV"
    run_tool
    [ "$status" -ne 0 ]
    [[ "$output" == *"no nameserver"* ]]
    grep -q 'inet dhcp' "$IFACES"
}

@test "an explicit nameserver satisfies a host that has none" {
    : > "$RESOLV"
    run_tool --nameserver 192.0.2.11
    [ "$status" -eq 0 ]
    grep -q '^nameserver 192.0.2.11$' "$RESOLV"
}

@test "a loopback stub is not written as if it were a real server" {
    # 127.0.0.53 is systemd-resolved's stub. Pinning it leaves the host
    # pointing at something that is not there once resolved is not running.
    printf 'nameserver 127.0.0.53\n' > "$RESOLV"
    cat > "$T/bin/resolvectl" <<'EOF'
#!/bin/sh
echo "  DNS Servers: 192.0.2.11"
EOF
    chmod +x "$T/bin/resolvectl"
    run_tool
    [ "$status" -eq 0 ]
    grep -q '^nameserver 192.0.2.11$' "$RESOLV"
    ! grep -q '127.0.0.53' "$RESOLV"
}

@test "a file that will not parse is put back, not left behind" {
    STUB_IFUP_FAIL=1 run_tool
    [ "$status" -ne 0 ]
    [[ "$output" == *"put back unchanged"* ]]
    grep -q 'inet dhcp' "$IFACES"
    ! grep -q 'inet static' "$IFACES"
}

@test "an interface configured some other way is refused, not rewritten" {
    printf 'auto lo\niface lo inet loopback\n' > "$IFACES"
    run_tool
    [ "$status" -ne 0 ]
    [[ "$output" == *"inet dhcp"* ]]
}

@test "no default route means there is nothing to read, and it says so" {
    STUB_NO_ROUTE=1 run_tool
    [ "$status" -ne 0 ]
    [[ "$output" == *"no default route"* ]]
}

@test "an address given without a prefix is refused" {
    run_tool --address 192.0.2.58
    [ "$status" -ne 0 ]
    [[ "$output" == *"prefix"* ]]
}

@test "the original interfaces file is kept as a backup" {
    run_tool
    [ "$status" -eq 0 ]
    ls "$IFACES".dejima-* >/dev/null 2>&1
    grep -q 'inet dhcp' "$IFACES".dejima-*
}

@test "a DHCP client still enabled is disabled" {
    cat > "$T/bin/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
  list-unit-files) [ "$2" = "dhcpcd.service" ] && exit 0; exit 1 ;;
  is-enabled)      [ "$2" = "dhcpcd" ] && exit 0; exit 1 ;;
  disable)         echo "disabled dhcpcd" >> "$STUB_LOG"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$T/bin/systemctl"
    export STUB_LOG="$T/systemctl.log"; : > "$STUB_LOG"
    run_tool
    [ "$status" -eq 0 ]
    grep -q 'disabled dhcpcd' "$STUB_LOG"
}
