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

SCRIPTDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
SCANNER="$SCRIPTDIR/Obsidian-Mirror-Scanner.sh"

SCANDIR="${OBSIDIAN_SCANDIR:-/opt/obsidian/var/scan}"
OBSIDIAN_DIR="${OBSIDIAN_DIR:-/opt/obsidian}"
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

    mkdir -p /var/run/netns 2>/dev/null
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
        echo "        iifname \"lo\" accept"
        echo "        ct state established,related accept"
        # allow only learned outbound endpoints (dir=out)
        "$SCANNER" learn -l "$LOG" 2>/dev/null | while read -r dir ep proto; do
            [ "$dir" = "out" ] || continue
            if [ "$proto" = "icmp" ]; then
                echo "        ip daddr $ep accept"
            else
                ip="${ep%.*}"; port="${ep##*.}"
                [ "$port" = "$ep" ] && continue
                echo "        ip daddr $ip $proto dport $port accept"
            fi
        done
        echo "        # everything else is denied by policy drop (egress)"
        echo "    }"
        echo "    chain ingress {"
        echo "        type filter hook input priority 0; policy drop;"
        echo "        iifname \"lo\" accept"
        echo "        ct state established,related accept"
        # allow only learned inbound endpoints (dir=in)
        "$SCANNER" learn -l "$LOG" 2>/dev/null | while read -r dir ep proto; do
            [ "$dir" = "in" ] || continue
            if [ "$proto" = "icmp" ]; then
                echo "        ip saddr $ep accept"
            else
                ip="${ep%.*}"; port="${ep##*.}"
                [ "$port" = "$ep" ] && continue
                echo "        ip saddr $ip $proto sport $port accept"
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
    if [ "${OBSIDIAN_DENY_NET:-0}" = "1" ]; then
        echo "ALLOW_NET       : 0  (network denied: OBSIDIAN_DENY_NET=1 set)"
    else
        echo "ALLOW_NET       : 1  (network allowed by default)"
    fi
    echo "ALLOW_WIFI      : 0  (hard-blocked in Layer 3)"
    echo "ALLOW_BLUETOOTH : 0  (hard-blocked in Layer 3)"
    # Layer 2 (strict boundary) status
    PROFILE=""
    for p in \
        "${XDG_CONFIG_HOME:-$HOME/.config}/obsidian/profiles/$KEY.profile" \
        "${XDG_CONFIG_HOME:-$HOME/.config}/obsidian/profiles/$KEY" \
        "/etc/obsidian/profiles/$KEY.profile" \
        "/etc/obsidian/profiles/$KEY" \
        "$OBSIDIAN_DIR/var/profiles/$KEY.profile" \
        "$OBSIDIAN_DIR/var/profiles/$KEY" \
        "$SCANDIR/../profiles/$KEY.profile" \
        "$SCANDIR/../profiles/$KEY"; do
        [ -f "$p" ] && PROFILE="$p"
    done
    if [ -n "$PROFILE" ]; then
        echo "HARDEN_OBSIDIAN=1 : ACTIVE (profile present: $PROFILE)"
    else
        echo "HARDEN_OBSIDIAN=1 : NOT ACTIVE (no profile learned/built)"
    fi
    # Layer 3 (network deny-list) status
    if nft list table inet "$TBL" >/dev/null 2>&1; then
        echo "HARDEN_OBSIDIAN=2 : ACTIVE (enforcing deny-list)"
        EG=$(nft list chain inet "$TBL" egress 2>/dev/null | awk '/packets/{p=$2} END{print p+0}')
        IN=$(nft list chain inet "$TBL" ingress 2>/dev/null | awk '/packets/{p=$2} END{print p+0}')
        echo "Red-flag OUTGOING drops : ${EG:-0} packets"
        echo "Red-flag INCOMING drops : ${IN:-0} packets"
    elif [ -f "$SCANDIR/$KEY.prior.log" ] || [ -f "$SCANDIR/$KEY.nft" ] || [ -f "$SCANDIR/$KEY.log" ]; then
        echo "HARDEN_OBSIDIAN=2 : LEARNED (network isolated on last run; set OBSIDIAN_DENY_NET=1 to enforce)"
    else
        echo "HARDEN_OBSIDIAN=2 : NOT ACTIVE (never run under HARDEN=2)"
    fi
    if [ ! -f "$SCANDIR/$KEY.log" ]; then
        echo "Learned traffic log : none (run OBSIDIAN_HARDEN=2 once to learn)"
        return 0
    fi
    echo "Learned traffic log : present"
    # permitted set = IPs in the allow-list (.nft)
    PERMITTED=""
    [ -f "$SCANDIR/$KEY.nft" ] && PERMITTED=$(grep -E 'ip (s?addr|daddr)' "$SCANDIR/$KEY.nft" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
    # parse learned endpoints into out/in lists (dir ip.port proto)
    OUT_L=$("$SCANNER" learn -l "$SCANDIR/$KEY.log" 2>/dev/null | awk '$1=="out"{print $2" "$3}')
    IN_L=$("$SCANNER" learn -l "$SCANDIR/$KEY.log" 2>/dev/null | awk '$1=="in"{print $2" "$3}')
    echo
    echo "--- OUTGOING Red-Flag block/deny/kill list (attempted, not permitted) ---"
    echo "$OUT_L" | while read -r ep proto; do
        ip="${ep%.*}"
        echo "$PERMITTED" | grep -qx "$ip" || echo "BLOCK  out  $ep  $proto"
    done | sort | uniq -c
    echo "--- INCOMING Red-Flag block/deny/kill list (attempted, not permitted) ---"
    echo "$IN_L" | while read -r ep proto; do
        ip="${ep%.*}"
        echo "$PERMITTED" | grep -qx "$ip" || echo "BLOCK  in  $ep  $proto"
    done | sort | uniq -c
}

kill_established() {
    KEY="$1"; LOG="$SCANDIR/$KEY.log"
    command -v conntrack >/dev/null 2>&1 || return 0
    [ -f "$LOG" ] || return 0
    allowed=$("$SCANNER" learn -l "$LOG" 2>/dev/null | awk '$1=="out"{print $2}' | sed 's/\.[0-9]*$//')
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
        HARDEN_OBSIDIAN=1 "$SCANNER" -k "$KEY" -- $APP &
        SC_PID=$!
        env -u OBSIDIAN_HARDEN OBSIDIAN_HARDEN=1 obsidian $APP
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
    tcpdump -n -tttt -v -i "$VH" "not (host 127.0.0.1 or host ::1)" > "$LOG" 2>&1 &
    CAP_PID=$!

    # if we already learned a deny-list, apply it now (enforce prior learning)
    if [ "${OBSIDIAN_DENY_NET:-0}" = "1" ]; then
        [ -f "$PRIOR" ] && apply_rules "$KEY"
    fi

    # launch the app inside the netns, through obsidian (HARDEN=1).
    # env -u guarantees the inner launcher can never re-enter the HARDEN=2 path.
    env -u OBSIDIAN_HARDEN OBSIDIAN_HARDEN=1 ip netns exec "$NS" obsidian $APP
    APP_RC=$?

    kill "$CAP_PID" 2>/dev/null; kill -9 "$CAP_PID" 2>/dev/null

    # promote this run's log to "prior" for next time, and (re)build rules
    [ -f "$LOG" ] && cp "$LOG" "$PRIOR" 2>/dev/null
    if [ "${OBSIDIAN_DENY_NET:-0}" = "1" ]; then
        build_rules "$KEY" "$LOG" >/dev/null
        # v3.4: mid-stream kill of any established connection not on the allow-list
        kill_established "$KEY"
    else
        warn "OBSIDIAN_DENY_NET not set: logging traffic, network allowed (set OBSIDIAN_DENY_NET=1 to enforce the deny-list)"
    fi

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
