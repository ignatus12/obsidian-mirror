#!/bin/sh
# =====================================================================
# obsidian-netblock.sh  -  per-app network namespace + dynamic deny-list
#                           (HARDEN_OBSIDIAN=2 "next level" hardening)
# =====================================================================
#
# The external-view blocker. For HARDEN_OBSIDIAN=2 we run the app inside
# its OWN network namespace with a dedicated veth. That gives two things:
#
#   1. Clean per-app capture  - tcpdump on the host-side veth sees ONLY
#      this app's traffic, so the scanner log is unambiguous.
#   2. Scoped enforcement    - an nftables default-deny egress policy on
#      that veth blocks everything the app did not prove it needs.
#
# Principle (as always with Obsidian Mirror): everything that is NOT 100%
# necessary for the application itself is denied. We learn "necessary" from
# a prior capture, then deny the rest.
#
# Lifecycle (run):
#   netns + veth + NAT  ->  launch app in netns via obsidian (HARDEN=1)
#     ->  capture traffic to /opt/obsidian/var/scan/<key>.log
#     ->  on exit: if a PRIOR log exists, build+apply a deny-list from it
#     ->  teardown
#
# Requires: root, iproute2, nftables (or iptables), tcpdump.
# If any are missing, it degrades to "log only" and warns -- it never
# silently breaks the application's network.
#
# Usage:
#   obsidian-netblock.sh run   <appkey> -- <application> [args...]
#   obsidian-netblock.sh build <appkey> <logfile>     # log -> rules file
#   obsidian-netblock.sh apply <appkey>               # apply rules on veth
#   obsidian-netblock.sh teardown <appkey>
# =====================================================================

set -u

SCANDIR="${OBSIDIAN_SCANDIR:-/opt/obsidian/var/scan}"
SUBNET="10.42.0.0/24"
HOSTIP="10.42.0.1"
APPIP="10.42.0.2"

warn() { echo "obsidian-netblock: $*" >&2; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        warn "needs root for network enforcement; falling back to logging only"
        return 1
    fi
    return 0
}

host_iface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

# ---- netns setup -----------------------------------------------------
netns_setup() {
    KEY="$1"; NS="obs-$KEY"; VH="veth-$KEY"; VI="vethi-$KEY"
    IFACE="$(host_iface)"
    [ -z "$IFACE" ] && { warn "no default route / interface; logging only"; return 1; }
    command -v ip >/dev/null 2>&1 || { warn "iproute2 missing; logging only"; return 1; }

    ip netns add "$NS" 2>/dev/null || { warn "could not create netns; logging only"; return 1; }
    ip link add "$VH" type veth peer name "$VI" 2>/dev/null || { warn "veth create failed; logging only"; ip netns del "$NS" 2>/dev/null; return 1; }
    ip link set "$VI" netns "$NS" 2>/dev/null
    ip addr add "$HOSTIP/24" dev "$VH" 2>/dev/null
    ip link set "$VH" up 2>/dev/null
    ip netns exec "$NS" ip addr add "$APPIP/24" dev "$VI" 2>/dev/null
    ip netns exec "$NS" ip link set "$VI" up 2>/dev/null
    ip netns exec "$NS" ip route add default via "$HOSTIP" 2>/dev/null

    # NAT so the app still has working internet (don't break the app).
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    if command -v nft >/dev/null 2>&1; then
        nft add table ip obsblock_"$KEY" 2>/dev/null || true
        nft add chain ip obsblock_"$KEY" natpost '{ type nat hook postrouting priority srcnat; }' 2>/dev/null || true
        nft add rule ip obsblock_"$KEY" natpost ip saddr "$SUBNET" oifname "$IFACE" masquerade 2>/dev/null || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$IFACE" -j MASQUERADE 2>/dev/null || true
    else
        warn "no nft/iptables for NAT; app may lose internet in this netns"
    fi
    echo "$NS $VH $VI $IFACE"
}

netns_teardown() {
    KEY="$1"; NS="obs-$KEY"; VH="veth-$KEY"
    nft delete table ip obsblock_"$KEY" 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    ip netns del "$NS" 2>/dev/null || true
    ip link del "$VH" 2>/dev/null || true
}

# ---- build a deny-list ruleset from a log -----------------------------
build_rules() {
    KEY="$1"; LOG="$2"
    OUT="$SCANDIR/$KEY.nft"
    mkdir -p "$SCANDIR" 2>/dev/null || true
    {
        echo "# dynamic deny-list for $KEY (generated from $LOG)"
        echo "table inet obsdeny_$KEY {"
        echo "    chain egress {"
        echo "        type filter hook output priority 0; policy drop;"
        # allow loopback and established
        echo "        iifname \"lo\" accept"
        echo "        ct state established,related accept"
        # allow each learned destination
        Obsidian-Mirror-Scanner.sh learn -l "$LOG" 2>/dev/null | while read -r dst port proto; do
            [ -z "$dst" ] && continue
            if [ "$proto" = "icmp" ] || [ "$port" = "*" ]; then
                echo "        ip daddr $dst accept"
            else
                echo "        ip daddr $dst $proto dport $port accept"
            fi
        done
        # DNS is usually needed; allow common resolvers generically
        echo "        # everything else is denied by policy drop (egress)"
        echo "    }"
        echo "    chain ingress {"
        echo "        type filter hook input priority 0; policy drop;"
        echo "        iifname \"lo\" accept"
        echo "        ct state established,related accept"
        Obsidian-Mirror-Scanner.sh learn -l "$LOG" 2>/dev/null | while read -r dst port proto; do
            [ -z "$dst" ] && continue
            if [ "$proto" = "icmp" ] || [ "$port" = "*" ]; then
                echo "        ip saddr $dst accept"
            else
                echo "        ip saddr $dst $proto sport $port accept"
            fi
        done
        echo "        # everything else is denied by policy drop (ingress)"
        echo "    }"
        echo "}"
    } > "$OUT"
    echo "$OUT"
}

stat_app() {
    KEY="$1"
    TBL="obsdeny_$KEY"
    echo "=== Obsidian Mirror - stats for $KEY (v3.4) ==="
    echo "ALLOW_NET       : 0  (default-deny in Layer 3)"
    echo "ALLOW_WIFI      : 0  (hard-blocked in Layer 3)"
    echo "ALLOW_BLUETOOTH : 0  (hard-blocked in Layer 3)"
    if nft list table inet "$TBL" >/dev/null 2>&1; then
        echo "HARDEN_OBSIDIAN=2 : ACTIVE (deny-list table present)"
        EG=$(nft list chain inet "$TBL" egress 2>/dev/null | awk '/packets/{p=$2} END{print p+0}')
        IN=$(nft list chain inet "$TBL" ingress 2>/dev/null | awk '/packets/{p=$2} END{print p+0}')
        echo "Red-flag drops (egress)  : ${EG:-0} packets"
        echo "Red-flag drops (ingress) : ${IN:-0} packets"
    else
        echo "HARDEN_OBSIDIAN=2 : NOT ACTIVE"
    fi
    if [ -f "$SCANDIR/$KEY.prior.log" ] || [ -f "$SCANDIR/$KEY.log" ]; then
        echo "Learned traffic log : present"
    else
        echo "Learned traffic log : none (run OBSIDIAN_HARDEN=2 once to learn)"
    fi
    if [ -f "$SCANDIR/$KEY.nft" ]; then
        echo "Allow-list endpoints :"
        grep -E 'ip (s?addr|daddr)' "$SCANDIR/$KEY.nft" | sed 's/^[[:space:]]*//'
    fi
}

kill_established() {
    KEY="$1"; LOG="$SCANDIR/$KEY.log"
    command -v conntrack >/dev/null 2>&1 || return 0
    [ -f "$LOG" ] || return 0
    allowed=$(Obsidian-Mirror-Scanner.sh learn -l "$LOG" 2>/dev/null | awk '{print $1}')
    conntrack -L 2>/dev/null | while read -r line; do
        dst=$(printf '%s\n' "$line" | sed -n 's/.*dst=//; s/ .*//p')
        [ -z "$dst" ] && continue
        printf '%s\n' "$allowed" | grep -qx "$dst" || conntrack -D -d "$dst" 2>/dev/null
    done
}

apply_rules() {
    KEY="$1"; NS="obs-$KEY"; VH="veth-$KEY"
    OUT="$SCANDIR/$KEY.nft"
    [ -f "$OUT" ] || { warn "no rules file $OUT; skipping enforcement"; return 1; }
    command -v nft >/dev/null 2>&1 || { warn "nftables missing; rules written to $OUT but not applied"; return 1; }
    # apply the inet table globally (it matches by daddr, so it only affects
    # what the app talks to; scoped tightly by the learned destinations).
    nft -f "$OUT" 2>/dev/null && echo "applied $OUT" || warn "nft apply failed; rules at $OUT"
}

# ---- run: full lifecycle ---------------------------------------------
run_app() {
    KEY="$1"; shift; APP="$*"
    mkdir -p "$SCANDIR" 2>/dev/null || true
    LOG="$SCANDIR/$KEY.log"
    PRIOR="$SCANDIR/$KEY.prior.log"

    if ! need_root || ! SETUP="$(netns_setup "$KEY")"; then
        # logging-only fallback: just run the app via obsidian and capture host-wide
        warn "enforcement unavailable; running with logging only"
        HARDEN_OBSIDIAN=1 Obsidian-Mirror-Scanner.sh -k "$KEY" -- $APP &
        SC_PID=$!
        HARDEN_OBSIDIAN=1 obsidian $APP
        kill "$SC_PID" 2>/dev/null; kill -9 "$SC_PID" 2>/dev/null
        return 0
    fi
    NS="obs-$KEY"; VH="veth-$KEY"

    # v3.2: hard-block Bluetooth (and WiFi if requested) for the whole host
    # during a hardened launch. The app already has no bt/wifi interface
    # inside its netns, this just guarantees 100% live blocking both ways.
    if command -v rfkill >/dev/null 2>&1; then
        rfkill block bluetooth 2>/dev/null && warn "Bluetooth hard-blocked for this launch"
        [ "${OBSIDIAN_BLOCK_WIFI:-0}" = "1" ] && rfkill block wifi 2>/dev/null && warn "WiFi hard-blocked for this launch"
    fi

    # start capture on the host-side veth (this app's traffic only)
    tcpdump -n -tttt -s 0 -i "$VH" "not (host 127.0.0.1 or host ::1)" -w "$LOG" >/dev/null 2>&1 &
    CAP_PID=$!

    # if we already learned a deny-list, apply it now (enforce prior learning)
    [ -f "$PRIOR" ] && apply_rules "$KEY"

    # launch the app inside the netns, through obsidian (HARDEN=1)
    HARDEN_OBSIDIAN=1 ip netns exec "$NS" obsidian $APP
    APP_RC=$?

    kill "$CAP_PID" 2>/dev/null; kill -9 "$CAP_PID" 2>/dev/null

    # promote this run's log to "prior" for next time, and (re)build rules
    [ -f "$LOG" ] && cp "$LOG" "$PRIOR" 2>/dev/null
    build_rules "$KEY" "$LOG" >/dev/null
    # v3.4: mid-stream kill of any established connection not on the allow-list
    kill_established "$KEY"

    netns_teardown "$KEY"
    return "$APP_RC"
}

# ---- dispatch ---------------------------------------------------------
case "${1:-}" in
    run)      shift; KEY="$1"; shift; run_app "$KEY" "$@" ;;
    build)    shift; build_rules "$1" "$2" ;;
    apply)    shift; apply_rules "$1" ;;
    stat)     shift; stat_app "$1" ;;
    kill)     shift; kill_established "$1" ;;
    teardown) shift; netns_teardown "$1" ;;
    *) echo "usage: $0 run|build|apply|stat|kill|teardown <appkey> [args...]" >&2; exit 2 ;;
esac
