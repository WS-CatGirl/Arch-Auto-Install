#!/usr/bin/env bash
#
# lib/install/stage-02-network.sh - stage 2: network environment check.
#
# Mirrors Config/Main/Plan-Main.md section "2." (network environment
# detection):
#
#   1. ping is an informational hint only - many networks drop ICMP, so it
#      must never decide whether the install may continue
#   2. at least one network interface must be UP (ip -o link show up)
#   3. DNS must resolve archlinux.org
#   4. curl -4 -fsS -I https://archlinux.org must succeed (real IPv4 egress)
#   5. any decisive check failing aborts immediately with a fix hint
#
# Every runtime message is pure ASCII (Plan-Main.md appendix C).
# The function is called by lib/install/main.sh; it takes no arguments.

# ---------------------------------------------------------------------------
# probe parameters
# ---------------------------------------------------------------------------
_NET_HOST='archlinux.org'
_NET_URL='https://archlinux.org'
# ICMP only: any well known address is fine, it is never a pass/fail gate.
_NET_PING_TARGET='1.1.1.1'
_NET_CURL_TIMEOUT='10'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
# Prints one line per UP interface, loopback excluded.
# A laptop with only "lo" up has no usable network and must not pass.
_net_up_interfaces() {
    local line name
    while IFS= read -r line; do
        [[ $line =~ ^[0-9]+:[[:space:]]+([^:@[:space:]]+) ]] || continue
        name="${BASH_REMATCH[1]}"
        [[ $name == 'lo' ]] && continue
        printf '%s\n' "$name"
    done < <(ip -o link show up 2>/dev/null || true)
}

_net_require_tools() {
    local tool
    for tool in ip curl getent; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            die "Required tool not found: ${tool}. Stage 2 cannot verify the network."
        fi
    done
}

# 1. informational ICMP probe - prints, never fails
_net_probe_icmp() {
    if ! command -v ping >/dev/null 2>&1; then
        log_warn 'ping not found, skipping the ICMP probe (informational only).'
        return 0
    fi
    if ping -c 1 -W 2 "$_NET_PING_TARGET" >/dev/null 2>&1; then
        log_info "ICMP probe to ${_NET_PING_TARGET}: reply received (informational)."
    else
        log_warn "ICMP probe to ${_NET_PING_TARGET}: no reply."
        log_warn 'Many networks drop ICMP; this is a hint, not a failure.'
    fi
    return 0
}

# 2. decisive: at least one interface must be UP
_net_require_interface() {
    local -a up_ifaces=()
    local line

    while IFS= read -r line; do
        [[ -n $line ]] || continue
        up_ifaces+=("$line")
    done < <(_net_up_interfaces)

    if (( ${#up_ifaces[@]} == 0 )); then
        log_error 'No network interface is UP (loopback excluded).'
        log_error 'Check the ethernet cable, connect the Wi-Fi, or plug in a'
        log_error 'USB network adapter, then inspect the links with: ip link'
        die 'Stage 2 aborted: no usable network interface.'
    fi

    log_ok "Network interface(s) UP: ${up_ifaces[*]}"
    return 0
}

# 3. decisive: archlinux.org must resolve
_net_require_dns() {
    local resolved=''

    resolved="$(getent hosts "$_NET_HOST" 2>/dev/null | head -n 1 || true)"
    if [[ -z $resolved ]]; then
        log_error "DNS lookup for ${_NET_HOST} failed."
        log_error 'Check /etc/resolv.conf, the DHCP lease, or the router;'
        log_error 'the live ISO normally receives DNS from the DHCP server.'
        die 'Stage 2 aborted: DNS resolution is broken.'
    fi

    log_ok "DNS resolves ${_NET_HOST} -> ${resolved%%[[:space:]]*}"
    return 0
}

# 4. decisive: real IPv4 egress to archlinux.org
_net_require_https() {
    if curl -4 -fsS -I --max-time "$_NET_CURL_TIMEOUT" "$_NET_URL" >/dev/null 2>&1; then
        log_ok "HTTPS reachable over IPv4: ${_NET_URL}"
        return 0
    fi

    log_error "Cannot reach ${_NET_URL} over IPv4 (curl -4 -fsS -I failed)."
    log_error 'Check the ethernet cable, the Wi-Fi, the router, or a captive'
    log_error "portal. Run 'curl -4 -v -I ${_NET_URL}' to see the exact error."
    die 'Stage 2 aborted: no working external network.'
}

# ---------------------------------------------------------------------------
# stage entry point
# ---------------------------------------------------------------------------
stage_02_network() {
    log_info 'Stage 2: network environment check.'

    _net_require_tools
    _net_probe_icmp
    _net_require_interface
    _net_require_dns
    _net_require_https

    log_ok 'Network looks usable. Continuing.'
}
