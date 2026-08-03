#!/bin/sh
# =====================================================================
# Obsidian Mirror Scanner  -  network traffic logger (testing phase, v1)
# =====================================================================
#
# The "external view" approach to the internal-application threat model.
#
# Instead of trying to inspect or block threats from *inside* an
# application (which is fragile and breaks apps), we watch everything
# the application tries to send *out* -- between the application and the
# real network -- log it, and analyse it. The Obsidian Mirror launcher
# already isolates the app's view of the host; this scanner isolates the
# app's view of the *network* by recording every packet that leaves it.
#
# In the Obsidian Mirror model this is the "EXTERNAL SUPER-BLOCKER"
# vantage point: place a logger here and you can see (and later block)
# the "magical mystery" traffic that an app attempts to transmit.
#
# What it captures
# -----------------
# All IP traffic on all interfaces (ethernet, wifi, VPN/tunnels, etc.)
# via a capture on the `any` interface. Known and unknown TCP/UDP ports,
# subnets and tunnels are all seen because they are just IP packets.
# (Bluetooth L2CAP/RFCOMM traffic needs `btmon`; run it alongside if you
# want the Bluetooth side too -- noted at the bottom.)
#
# Usage
# -----
#   Obsidian-Mirror-Scanner.sh [options] -- <application> [args...]
#   Obsidian-Mirror-Scanner.sh -l firefox.log -d 120 -- firefox
#   Obsidian-Mirror-Scanner.sh -n -- chromium          # run via obsidian
#
# Options
#   -l FILE   log file                       (default: Obsidian-scanner.log)
#   -d SECS   capture duration in seconds    (default: until the app exits)
#   -i IFACE  capture interface              (default: any)
#   -n        also run the app through obsidian (isolation)
#
# Environment overrides: OBSIDIAN_SCANNER_LOG / _DURATION / _IFACE
# =====================================================================

set -u

LOG="${OBSIDIAN_SCANNER_LOG:-Obsidian-scanner.log}"
DURATION="${OBSIDIAN_SCANNER_DURATION:-}"
IFACE="${OBSIDIAN_SCANNER_IFACE:-any}"
VIA_OBSIDIAN=0
APP=""

while [ $# -gt 0 ]; do
    case "$1" in
        -l) LOG="$2"; shift 2 ;;
        -d) DURATION="$2"; shift 2 ;;
        -i) IFACE="$2"; shift 2 ;;
        -n) VIA_OBSIDIAN=1; shift ;;
        --) shift; APP="$*"; break ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
         *)  APP="$*"; break ;;
    esac
done

if [ -z "$APP" ]; then
    echo "usage: $0 [options] -- <application> [args...]" >&2
    exit 2
fi

# --- pick a capture engine -------------------------------------------
if command -v tcpdump >/dev/null 2>&1; then
    CAP="tcpdump"
elif command -v tshark >/dev/null 2>&1; then
    CAP="tshark"
elif command -v dumpcap >/dev/null 2>&1; then
    CAP="dumpcap"
else
    echo "ERROR: no packet capture tool found (need tcpdump, tshark or dumpcap)." >&2
    exit 1
fi

echo "Obsidian Mirror Scanner"
echo "  application : $APP"
echo "  capture     : $CAP on interface '$IFACE'"
echo "  log file    : $LOG"
[ -n "$DURATION" ] && echo "  duration    : ${DURATION}s"
[ "$VIA_OBSIDIAN" -eq 1 ] && echo "  launch      : via obsidian (isolated)"

# --- start capture in the background --------------------------------
case "$CAP" in
    tcpdump)
        # -n        : do not resolve names (raw facts)
        # -tttt     : full timestamp
        # -v        : verbose (flags, ttl, options)
        # -s 0      : full packet
        # exclude loopback so we see only real egress
        tcpdump -n -tttt -v -s 0 -i "$IFACE" \
            "not (host 127.0.0.1 or host ::1)" \
            > "$LOG" 2>&1 &
        CAP_PID=$!
        ;;
    tshark|dumpcap)
        tshark -i "$IFACE" -w "$LOG" >/dev/null 2>&1 &
        CAP_PID=$!
        ;;
esac

# --- launch the application -----------------------------------------
if [ "$VIA_OBSIDIAN" -eq 1 ] && command -v obsidian >/dev/null 2>&1; then
    obsidian $APP &
else
    $APP &
fi
APP_PID=$!

# --- wait ------------------------------------------------------------
if [ -n "$DURATION" ]; then
    sleep "$DURATION"
else
    wait "$APP_PID" 2>/dev/null
fi

# --- stop capture -----------------------------------------------------
kill "$CAP_PID" 2>/dev/null
sleep 1
kill -9 "$CAP_PID" 2>/dev/null

LINES=$(wc -l < "$LOG" 2>/dev/null || echo '?')
echo
echo "Capture stopped."
echo "  log   : $LOG"
echo "  lines : $LINES"
echo
echo "Next: read $LOG to see every connection the app attempted."
echo "To turn observation into blocking, feed these destinations into"
echo "a deny list (e.g. unbound / nftables) -- the external view, not"
echo "the in-app view."
echo
echo "Bluetooth note: for L2CAP/RFCOMM traffic, run in another terminal:"
echo "    btmon -w Obsidian-scanner-bt.log"
echo "and launch the app the same way."
